# Architecture and module contracts

This is the binding contract between modules.  A module may rely on
anything written here and on nothing else about another module.  If a
module needs something more, add it here first.

## Layers

```
 Presentation   lisp/ui/*        Emacs buffers, faces, keymaps, mouse.  Talks ACP only.
                                 Runs in the user's Emacs; everything below runs in
                                 the harness process (see Processes).
 ------------------------------- ACP (JSON-RPC over loopback TCP; in-process lisp objects
                                 when `harness-process' is nil)
 State          session, agent, config, project, store, usage, insights, fallback,
                retry, naming, judge, compaction, handoff, worktree, merge, tasks,
                tasks-notify, supervisor, seed, skills, perms, decisions, sandbox,
                notifications, secrets, redact, plugins
 Completion     provider, provider-openai, provider-deepseek, provider-claude,
                provider-bedrock, provider-copilot
 Tool calls     tools, tools-fs, tools-shell, tools-ssh, tools-emacs, tools-emacs-eval,
                tools-web, tools-agent, tools-question, tools-plan, tools-todo,
                tools-session-info, tools-sessions, tools-events, tools-notify,
                tools-handin, tools-compact
                 (and this repository's own plugin: .harness/plugins/dev/, tools-dev
                 and ui-tools-dev; see Projects' plugins)
 ------------------------------- bus (lisp/harness-core.el)
 Core           harness.el (loader, reload), harness-core (methods, events, filters,
                promises, modules), harness-util (json, ids, paths, the thinking-level
                order), harness-http (curl, SSE, binary bodies), harness-policy (settings
                an administrator fixes), harness-slots (pools: at most so many at once),
                harness-redaction (naming a secret, finding it, taking it out of text)
```

The core never shows UI and never calls a model.  UI modules never
`require` a state module and never touch a session struct: they hold
an ACP connection (local by default) and render what arrives.  State
modules never `require` a UI module.  That is the litmus test from
DESIGN.md: every module is testable alone, with a fake connection or a
fake provider, and without mocks of the rest.

## Processes

Emacs runs Lisp on one thread, so harness work done in the user's Emacs
competes with typing and redisplay no matter how asynchronous the
protocol around it is: an ACP request to an in-process harness still
runs its handler on the UI's thread.  With `harness-process` on (the
default) the layers above are split across two Emacs processes:

```
 user's Emacs                         harness process (emacs --batch -Q)
 harness.el, core, lisp/ui,     ACP   harness.el, core, lisp/modules
 harness-acp (client only),  <------> (acp serves 127.0.0.1:ephemeral,
 harness-files,               TCP     token per spawn; every tool runs here),
 harness-emacs-endpoint,              the user's other modules
 the user's UI modules
```

- `harness-start` in the user's Emacs loads only the UI (with the UI
  modules of `harness-extra-module-directories`, see Modules of your
  own) and the ACP client, then `harness-server-spawn`
  (lisp/harness-server.el) starts the child once init has finished, so
  settings made later in the init file reach it.  Requests made before
  the child listens are queued by `harness-ui`.
- The child is configured from a generated file: every `harness-`
  variable the user set (minus those a UI module defines, told by the
  name of its file, `harness-ui[-NAME].el`: what loads is a compiled
  copy in the state directory), `harness-extra-module-directories` made
  absolute, the TRAMP options the user set
  (`harness-server--tramp-variables`: default methods, users and hosts,
  proxies, `tramp-remote-path`, connection sharing), plus
  `harness-server-forward-variables`; `harness-server-init-file` covers
  anything else (hooks, bus filters).  The policy (an administrator's
  file, see [policy.md](policy.md)) is not forwarded: each process
  reads `/etc/harness/policy.el` itself, which overrides the user's
  values there too, and `harness-policy-file` stays behind.
- The child announces `HARNESS-ACP-ADDRESS host:port` and its log lines on
  stderr (batch Emacs buffers stdout); the parent copies the log into
  `*harness-log*`.  Its stdin is closed, so a stray prompt fails rather
  than hangs; it exits when its parent dies.  The parent restarts it
  with backoff when it crashes and stops it with SIGTERM (which runs
  `kill-emacs-hook`, flushing sessions, tasks and streamed text); the
  end of a process it already replaced, reported late, changes nothing.
  `M-x harness-restart` restarts it with fresh configuration;
  `harness-reload` reloads both sides: the UI first, then it asks the
  process (`harness/reload`), which answers whether every file loaded,
  some failed to, or none were loaded because one does not compile.
- The child's event loop (`harness-server--event-loop`) never sleeps past
  the earliest timer.  Batch Emacs runs due timers from a copy of
  `timer-list` inside `accept-process-output` and then sleeps until the
  next timer of that copy, so a timer a timer starts -- every
  `harness-run-soon` of a request handler, the next step of a turn --
  would otherwise wait for an unrelated timer or process output, seconds
  later.
- An error that escapes a process filter or sentinel goes to
  `command-error-function`, whose batch default ends Emacs with status
  255: every running turn stopped at once, and the parent restarted the
  process ("Harness process exited (status 255); restarting").  The
  child sets its own (`harness-server--guard`), which logs the error
  and carries on.  One such error was `max-lisp-eval-depth`:
  `process-send-string` to a peer that does not read waits for room in
  20 ms slices, running timers and filters meanwhile, and one that
  writes to the same peer waits inside it, and so on, a frame deeper
  each time, until Lisp nesting overflows.  The handler throws such an
  overflow back to the event loop (`harness-server--unwind`), so the
  nested waits unwind rather than stop the process, and every write to
  a peer goes through `harness-process-send` (lisp/harness-util.el): a
  write that meets one in flight to the same process queues behind it,
  and the one in flight sends it when it is done, in order, so the
  waits never nest.  A write that waits longer than
  `harness-process-send-slow` (10 s) is logged; given a limit (the
  remote server's WebSocket, `harness-acp-remote--write-limit`, 120 s),
  a write that comes in line behind one waiting longer than that closes
  the peer, which has not read for so long, and the write in flight
  fails rather than wait on.
- The UI reads the child's socket when its event loop reports it
  readable, and handles what it read from a timer, a slice at a time
  (`harness-acp-receive-slice`; see acp).  The loop does not always get
  to report it.  While a timer keeps setting itself ripe -- `run-at-time`
  0 from its own function, an idle timer set again from the idle job --
  Emacs runs the timers due, redisplays, and runs the timers due again,
  and never reaches its select: timers keep firing and the screen keeps
  updating, but the socket's filter is not called until the next click
  or key, so the chat shows what the harness did only then.  (A filter
  with a feeder process, 0 calls in six seconds, 59 in sixty with the
  poll below.)  The quick search's idle build of its scan of the
  commands did this to a UI left alone, once a hot reload had left a
  command defined that its library no longer has: Emacs loads a library
  again at every read of the documentation of such a command, a load
  marked the scan stale, and the build began again at once (see the quick
  search).  GUI Emacs on macOS may also leave the socket unread: its
  select hands the file descriptors to a helper thread and waits for that
  thread's wake-up; the symptom is that of a wake-up lost.  A select with
  a zero timeout waits for no one, and does read them.  So
  `harness-acp-client-poll-interval` (0.1 s on every system; nil turns it
  off) has one repeating timer read every open TCP client connection that
  often (see acp).
- Every tool runs in the harness process; no client runs one, so an
  ACP client that is not an Emacs (a phone) loses nothing, and the
  harness works headless.  The user's Emacs is a resource some tools
  reach, as a TRAMP host is for the file tools: the UI lends it to the
  harness when it connects (`clientCapabilities._harness.emacs` in
  `initialize`), and the harness sends that one Emacs the small, fixed
  set of `_harness/emacs/*` requests of lisp/harness-emacs-endpoint.el
  through `emacs/request` (see the tools and acp sections).  The
  `emacs_*` tools of tools-emacs ask it for plain data and a few
  bounded actions (show a buffer, insert text, save one, trace a
  function or a variable); none evaluates code.  The `elisp` tool
  evaluates in a child `emacs --batch` (lisp/harness-elisp.el), never
  in the lent Emacs, and that child runs in the sandbox as a `bash`
  command does.  Model-written Lisp reaches the lent Emacs only
  through `emacs_eval` (tools-emacs-eval), which the user can turn off
  with `harness-emacs-eval` (on by default): the code runs on the UI's
  only thread, where a blocking call freezes typing and redisplay,
  so a judge model must expect it to return at once, the permission
  chain must allow the call as it would a bash command, and the lent
  Emacs runs it guarded (the user's next key or C-g stops it; it may
  not prompt; it is stopped once it has waited two seconds).  The lent
  Emacs checks the setting itself, so it has the last word.  The
  harness's methods are in the harness process, not in this Emacs, so
  the code's `harness-call` of one goes there over the connection the
  request came on (`harness-call-fallback-function`, `harness/call`;
  see the bus and acp).
- Chores of the UI, which any client may do, are asked for with
  `client/request` (below): saving user options to `custom-file`
  (`harness-save-user-option`), reverting buffers after a tool
  writes a file (event `tools/file-written`), and desktop notifications
  (lisp/harness-notifications-desktop.el, see notifications), so they
  show where the user is and a click on one opens what it is about.
- Project roots and file lists (lisp/harness-files.el) are computed on
  both sides with the same code; the UI lists files itself so `@`
  completion uses the user's projectile cache.
- The redaction library (lisp/harness-redaction.el, see
  harness-redaction below) is loaded on both sides.  The harness process
  redacts the stores with it; the UI uses it to take a secret out of the
  buffers of the user's Emacs, which the harness cannot reach.
- The Claude plugin library (lisp/harness-claude-plugin.el, see
  "Looking like an ordinary Claude Code session" under provider) is
  loaded on both sides like the others, but only the harness process
  uses it: it writes the plugin into the state directory and listens on
  127.0.0.1 for the plugin's relay.
- Each side notes the commit it loaded the harness from
  (lisp/harness-revision.el, see version): the two load their files
  separately, so a restart of the process alone can leave them on
  different commits.

The harness process cannot prompt: TRAMP connections it opens need
non-interactive authentication (ssh agent, a key without a passphrase,
a known host key), and auth-source secrets must decrypt without a
minibuffer (gpg-agent pinentry, not loopback).  A TRAMP prompt reads the
closed stdin and fails at once with `end-of-file`; the ssh tool says so
(see tools-ssh).

`harness-process` nil keeps everything in one Emacs (tests, debugging);
the same `client/request` and `emacs/request` paths then run over the
local connection.

## The bus

```elisp
(harness-define-module 'NAME :doc "…" :requires '(a b) :init #'fn :shutdown #'fn) ; :init runs at every reload
(harness-defmethod session/get (id) "Doc." …)          ; registers method `session/get'
(harness-call 'session/get id)                         ; sync; may return a promise
(harness-call-async 'session/get id)                   ; always a promise
(harness-on 'session/updated #'named-fn)               ; events; named fns dedupe on reload
(harness-emit 'session/updated id changes)
(harness-add-filter 'agent/system-prompt #'fn 40)      ; sync value transformer
(harness-run-filter 'agent/system-prompt "" session)
(harness-run-filter-async 'permission/decide decision request) ; async decision chain
```

`harness-call-fallback-function` (nil) answers `harness-call` for a
method this Emacs does not have: while it is non-nil and no method NAME
is registered here, `harness-call` (and so `harness-call-async`)
returns what `(funcall FN NAME ARGS…)` returns instead of signalling
`harness-no-such-method`.  A method registered here is still called
here, and `harness-method-exists-p` and `harness-methods` do not look at
the function, so a module that asks whether a method exists before it
uses one sees what it always saw.  The variable is let-bound around code
that runs away from the bus it calls, never set: the Emacs endpoint
binds it while it evaluates the code of `emacs_eval`, so that code
reaches the harness process over the connection its request came on
(see acp, `harness/call`).

Async filter gotcha: `harness-run-filter-async` adopts any promise a
handler returns and calls NEXT with its value.  A handler that stores
NEXT to call later (merge holds, budget prompts) must return nil.
`harness-run-filter-async-between NAME FROM TO VALUE &rest ARGS` runs
only the handlers whose priority lies between FROM and TO, inclusive
(the perms module re-decides a waiting prompt through the stages after
the jail with it).  `harness-run-filter-async-traced NAME VALUE ARGS
&key FROM TO TRACER` runs the chain the same way, between FROM and TO
when they are given, and calls TRACER as (TRACER FN OLD NEW) each time
a handler FN hands on a value NEW that is not `eq` to the value OLD it
was given, so a caller can tell which handler changed it (the tools
module names the permission stage that decided a call with it; see
perms).

An error signalled inside a `harness-then` handler rejects the derived
promise *and* is logged (with a backtrace when `harness-log-level` is
`debug`), because a rejection nobody observes would otherwise vanish.
Explicit rejections (`harness-reject`, `harness-rejected`) are not logged.

Promises: `harness-make-promise`, `harness-resolve`, `harness-reject`,
`harness-then`, `harness-all`, `harness-with-promise`, `harness-await`
(tests only).  Long work returns a promise; never block the main thread.

Naming: bus methods are `area/verb` symbols and are exactly the ACP
extension methods (`_harness/area/verb` on the wire).  Events are
`area/past-tense`.  Files: `lisp/modules/harness-NAME.el` defines
module `NAME` and provides feature `harness-NAME`; a UI module is `ui`
or `ui-NAME`, in `lisp/ui/harness-ui-NAME.el`.  The directories of
`harness-extra-module-directories` hold modules named the same way
(see Modules of your own).

Reload safety: keep state in `defvar`s (never re-initialised), register
subscribers with named functions, and make `:init` idempotent: every
`harness-reload` runs the `:init` of each ready module again, so that
what new code subscribes there takes effect without a restart.
`harness-on`, `harness-add-filter` and `add-hook` add a named function
once, at the priority the latest code gives.  Work to do once per start
-- reading state from disk, recovering what a stopped harness left,
connecting, starting a server -- checks `(harness-module-ready-p
'NAME)` first, which is nil while the module starts and non-nil when it
initialises again.  A ready module whose `:init` fails again stays
ready with what it set up before, and the reload reports the error; a
disabled module stays off.
`harness-reload` compiles every file first and refuses to load anything
if one fails.  It loads harness.el, the core files, the libraries of
lisp/ (`harness--library-files`: policy, files, redaction, the Emacs
endpoint, desktop notifications, server, revision, module docs, slots) and the
modules, so a module never runs against a library as it was before an
update; a file added to lisp/ that both sides load belongs in one of
those lists.  Records made before a reload
keep their layout: a slot added to a struct goes last and is read in a
way that tolerates records without it (see `harness-acp--client-get`),
or the module drops its stale records (see
`harness-provider-claude--drop-stale-entries`).  After a reload the
`harness/reloaded` event fires and the UI redraws every session buffer.
A reload loads the modules selected now (below) but stops none: one no
longer enabled runs on until a restart, and the reload says so.

## Which modules load

Out of the box the harness loads its core, `harness-core-modules`:
sessions and the turn loop, the Claude Code provider of the default
model, compaction and retries, session names, the file, shell and
Emacs tools with the permissions and the sandbox that guard them, the
question, plan, todo, session info and sub-agent tools (a module
each), worktrees, usage, and the chat, session list and pending
requests of the UI.  Everything else is
enabled by the user, Doom style, with `harness-enable-modules` (which
sets `harness-enabled-modules`), or at once with `M-x
harness-enable-module`; `harness-enabled-modules` t loads every module.
`harness--selected-modules` decides, the same way on both sides of the
process split, from every module file of either side
(`harness--module-sources`):

- The core and the enabled modules load, with what each brings along
  (`harness--module-closure`): the modules of its `:requires`, the
  harness files it `require`s at top level -- a module that requires
  another's file loads it, libraries of lisp/ui such as ui-drag
  included, so they load compiled -- and its other half, `ui-NAME` for
  `NAME` and `NAME` for `ui-NAME`.  They are read from the source
  without loading it (`harness--module-header`).
- `harness-disabled-modules` leaves its modules out, with their UI
  halves, whatever brings them; a module requiring one fails to start.
- Each side then loads the files of its own directories
  (`harness--module-files`), in directory then name order.

A module requires only modules that load where it does.  The user's
Emacs loads the UI modules and the ACP client, the harness process the
others, and a module whose requirement loads on the other side never
starts (`harness-module-start`): its feature is missing, and the start
says `modules failed: NAME`.  So a UI module never requires its harness
half -- the two halves of a feature talk over ACP and never require
each other, and the loader brings the other half along by its name.
`harness-loader-modules-require-only-what-loads-where-they-do` checks
every module's requirements on both sides.

The harness's guards, perms and sandbox, are core modules: they load
whatever the user enables, and only `harness-disabled-modules` takes
them out (see docs/policy.md).  A name `harness-enabled-modules` has
that no module has is reported at `harness-start`.

## Pages of the modules

Every module documents itself: `lisp/harness-module-docs.el` reads
from a module's source, without loading it, what it provides to the
others -- methods, tools, model providers, events, the filter chains
it runs, hooks, commands, options -- and what it uses of them: the
modules it requires and brings along, the methods it calls (and
whether it does without them), the events it handles on the bus or
hears over ACP, those it emits, the filter chains it joins and the
hooks it adds to.  `scripts/module-docs.sh` writes a page for each in
docs/modules/ and an index whose tables cross the events, filter chains
and hooks with the modules on either side of them, with the
`harness-enable-modules` template of every optional module;
`scripts/module-docs.sh --check` says whether they are up to date, and
`M-x harness-describe-module` shows a page in Emacs.  Run the script
after changing what a module provides or uses, and commit the pages.

The pages see what the code says plainly, so a module keeps to these:

- `:doc` says in a line what the module is; the Commentary section of
  its file, which the page shows as its About, says how it works.
- Names are quoted where they are used: `(harness-on 'area/event ...)`,
  `(harness-call 'area/verb ...)`, `"_harness/area/verb"` in the UI.  A
  `dolist` over a quoted list of them is read too; a name computed at
  run time is not.
- Events are declared (`harness-declare-event`) by the module that
  emits them, and an event a UI module hears is forwarded to the UI
  (`harness-acp--forwarded-events`, or `harness-acp-extra-events` for a
  module of your own).  A UI module hears events in a function it adds
  to `harness-ui-event-functions`, comparing the event with literal
  names (`"task/changed"`) or prefixes (`"merge/"`).  A test of
  test/harness-module-docs-test.el fails when an event is emitted
  undeclared, or heard in the UI but never forwarded there.
- Handlers are named functions, as reload safety wants anyway.

docs/module-audit.md is an audit of the modules and their API made
with these pages, and what is left to do about it.

## Modules of your own

A module of the user's own lives outside the harness's tree, in a
directory of `harness-extra-module-directories` (absolute, or relative
to `user-emacs-directory`).  It is bound by this document as the
harness's own modules are.  `harness--module-files` decides what loads
where:

- Every `harness-NAME.el` of such a directory is module `NAME`, which
  `harness-enabled-modules` and `harness-disabled-modules` select as
  they select the harness's own (Which modules load, above): a module
  of your own loads once enabled, or when an enabled module brings it.
  Its other files are not modules.  The directories are on `load-path`,
  after everything else so that no file there shadows a library, so a
  module may `require` its other files.  Only module files are
  compiled and reloaded.
- A UI module (`ui` or `ui-NAME`, `harness--ui-module-p`) loads where
  lisp/ui does: in the user's Emacs.  Any other module loads where
  lisp/modules does: in the harness process, or in the user's Emacs
  when `harness-process` is nil.  As in Layers, the two halves of a
  feature talk over ACP and never `require` each other.
- They load after the harness's own modules, a directory at a time.  A
  module whose name is taken is left out with a warning in
  `*harness-log*` rather than replacing what has the name: one of the
  harness's modules, core files or libraries, or a module of a
  directory listed earlier.
- They compile into the state directory and reload as the harness's
  own do.  `harness-reload` and `harness-update` load nothing when one
  of them does not compile, and `harness-auto-reload-mode` watches their
  directories.  A module records its source as `harness-module-file`
  (from `harness--defining-file` while it loads), not the compiled copy
  that `load-file-name` names.
- The harness process gets the directories made absolute when it
  starts (its `emacs -Q` has its own `user-emacs-directory`), so a
  change takes `harness-restart`.  A reload never changes them, and no
  request over ACP does either.
- The options of a module are forwarded to the harness process like any
  `harness-` variable the user set, whether this Emacs loads the module
  or not: an option set before its module loads has no `symbol-file`,
  so it is the user's.  The options of a UI module stay in the user's
  Emacs.  Only `harness-...` variables are forwarded (list the others in
  `harness-server-forward-variables`), so a module names its options
  `harness-NAME-...`.  `config/describe` lists those of the `harness`
  group under the module's name.
- Over ACP, a module's methods are callable as `_harness/NAME` once
  their prefix is in `harness-acp-extra-method-prefixes`.  Its events
  reach clients as `_harness/event` once they are in
  `harness-acp-extra-events`, and the UI hears them through
  `harness-ui-event-functions` (EVENT a string, ARGS a list).  A module
  adds to both as it loads, with `with-eval-after-load 'harness-acp`,
  which holds in the harness process when `harness-process` is on.
- `harness/modules` describes the modules of a harness, as
  `harness-module-descriptions` does (name, state, doc, file, error).
  `harness-describe-modules` lists those of the user's Emacs, then
  those of the harness process, through
  `harness-describe-modules-functions`.  For a module from outside the
  tree, the list names its file.

A minimal pair, in `~/.config/emacs/harness-modules/`, with
`harness-extra-module-directories` set to `("harness-modules")`:

```elisp
;;; harness-hello.el --- Says hello  -*- lexical-binding: t; -*-
(require 'harness-core)

(defcustom harness-hello-greeting "Hello"
  "How `hello/greet' greets."
  :type 'string :group 'harness)

(harness-defmethod hello/greet (name)
  "Greet NAME, and tell every client."
  (harness-emit 'hello/greeted name)
  (format "%s, %s!" harness-hello-greeting name))

(defvar harness-acp-extra-method-prefixes)
(defvar harness-acp-extra-events)
(with-eval-after-load 'harness-acp
  (add-to-list 'harness-acp-extra-method-prefixes "hello/")
  (add-to-list 'harness-acp-extra-events 'hello/greeted))

(harness-define-module 'hello :doc "Says hello.")
(provide 'harness-hello)
```

```elisp
;;; harness-ui-hello.el --- Asks hello to greet  -*- lexical-binding: t; -*-
(require 'harness-ui)

(defun harness-hello (name)
  "Have the harness greet NAME."
  (interactive "sName: ")
  (harness-ui-call "_harness/hello/greet" (list :name name)
                   (lambda (greeting) (message "%s" greeting))))

(defun harness-ui-hello--on-event (event args)
  "Say whom the harness greeted, whichever client asked."
  (when (equal event "hello/greeted")
    (message "The harness greeted %s" (car args))))

(add-hook 'harness-ui-event-functions #'harness-ui-hello--on-event)

(harness-define-module 'ui-hello :doc "Asks hello to greet." :requires '(ui))
(provide 'harness-ui-hello)
```

`harness-server-loads-extra-modules-on-each-side`
(test/harness-server-test.el) runs such a pair, one module in each
process.

## Projects' plugins

A project may carry modules of its own, for what only makes sense in
it: its plugins.  The harness's own repository has one,
.harness/plugins/dev/ (tools-dev and ui-tools-dev: `open_harness` and
the board's Open harness), which is why those are no modules of the
harness.  The harness loads no plugin: Emacs does, as it applies any
project's directory-local variables (lisp/modules/harness-plugins.el,
module `plugins`).

- Loading.  The project's .dir-locals.el requires the plugin in an
  `eval` entry and names the plugin modules its sessions use in
  `harness-plugin-modules` (the repository's own .dir-locals.el is the
  example; its `eval` loads nothing from a checkout nested in another,
  such as a task's worktree, since in the user's Emacs a worktree's
  copy of the trusted entry would load the worktree's plugin files).
  The required file loads each half once what it needs has
  loaded (`with-eval-after-load` of harness-tools, of a UI library), as
  .harness/plugins/dev/harness-dev-plugin.el does, since both Emacsen
  apply the same entries.  A module defined after `harness-started` by
  code other than the loader starts by itself at the next turn of the
  event loop, unless `harness-disabled-modules` names it
  (`harness-define-module`); `harness-plugins--apply` starts those it
  loaded at once.  A plugin's code loads once per process (`require`):
  neither `harness-reload` nor `harness-auto-reload-mode` reloads it.
- Trust.  A plugin is the project's Emacs Lisp, run outside the
  sandbox, so Emacs's own trust decides: neither entry is safe as it is
  (`harness-plugin-modules` has no `safe-local-variable`), so the
  user's Emacs asks, and `!` records them in
  `safe-local-variable-values`.  The harness process asks nobody:
  `harness-plugins--apply` runs `hack-dir-local-variables-non-file-buffer`
  in a buffer of its own with `enable-local-variables` `:safe` (nil
  stays nil; `:all`, or a directory that `safe-local-variable-directories`
  names, gives `:all`), so only what is safe or trusted applies, and
  only for a project whose variables set `harness-plugin-modules`
  (`harness-plugins--names-modules-p` reads them first, evaluating
  nothing): other projects' trusted `eval` entries never run in the
  process.  The user's settings (`harness-server-dir-locals-variables`)
  reach it as the user set them when it starts
  (`harness-server--forwarded`, their global values) and, whenever one
  changes in the user's Emacs, through `plugins/trust` (a variable
  watcher in harness-ui.el).  It applies
  the variables of the session's project's main checkout
  (`harness-files-owning-checkout`), never a linked worktree's, nor a
  remote one's.  `harness-plugin-modules` is the init file's alone
  besides: `harness-config-hidden-options` keeps it off the settings
  page and `config/set`.
- Freezing.  A session takes its list as it starts, which is when it
  enters the jail: `harness-plugins--on-created`, a subscriber of
  `session/created`, keeps it in the session's `:ext` under `:plugins`
  (names as strings, `:false` for none), where it stays across
  restarts.  A session with a `:parent-id` (fork, sub-agent, side
  conversation), or made while a tool call of another session runs
  (`harness-tools-calling-session`, which `harness-tools--run-handler`
  binds around a handler: task_submit's task), takes that session's
  frozen list, or none once it is gone; any other, what its checkout
  names then.  No checkout a jailed agent could have made is applied
  (`harness-plugins--planted-p`, in `harness-plugins--checkout`): one
  in the sessions' temporary root, in a .git directory, or below
  another checkout (ancestors up to the home directory, exclusive),
  however the session reached it -- its own directory or a worktree's
  .git file -- since a copy of a trusted .dir-locals.el is trusted
  wherever it is.  Nothing a session
  does changes its list or its children's; only the user trusting a new
  value, outside every jail, changes what the next sessions get.  A
  session from before this freezes its list the first time
  `plugins/of-session` is asked for it.  After a restart,
  `plugins/of-session` applies a session's checkout (and its parents')
  once per process first, so the plugin's code is there again.
- Scope.  `harness-module-plugin-p NAME` is true for a module whose
  file (`harness-module-file`) lies outside the directories the harness
  loads modules from (`harness--own-module-directories`: lisp/modules,
  lisp/ui, `harness-module-directories`,
  `harness-extra-module-directories`).  A tool belongs to the module of
  the harness-NAME.el file loading as it is defined, else to the module
  the loader is loading (`harness-loading-module`).  A plugin module's
  tool is offered to, and callable by, only the sessions whose frozen
  list names that module, once it is ready (see the tools contract,
  `harness-tools--in-scope-p`).  Methods and events are not scoped: a
  plugin's methods are callable by any client once their prefix is in
  `harness-acp-extra-method-prefixes`.
- Registration.  What the harness lists for its own tools a plugin
  adds as it loads, at top level: methods' prefixes to
  `harness-acp-extra-method-prefixes`, tools that need no approval to
  `harness-perms-extra-auto-allow-tools`, tools that start processes
  to `harness-tool-slots-tools`, and actions on a task board's cards to
  `harness-ui-tasks-action-functions` (UI side).
- This repository's tests find its plugins' modules as they find
  lisp/modules' (`harness-test-load-module`,
  `harness-test-plugin-directories`), and scripts/lint.sh compiles
  them.  A development Emacs (scripts/harness-dev.el) sets
  `enable-local-variables` to `:safe`, so it never asks and loads no
  plugin unless its user trusts it there.

Methods of `plugins`:

| Method | Params | Returns |
|---|---|---|
| `plugins/of-session` | id | the plugin modules session ID froze, a list of symbols (freezing it first when it has not; nil for no such session) |
| `plugins/trust` | values: an alist of `harness-server-dir-locals-variables` and their values, printed | the names of the variables set (any other variable is ignored) |

Both are callable over ACP as `_harness/plugins/...`.

test/harness-plugins-test.el, `harness-core-plugin-modules-are-those-the-harness-did-not-load`
(test/harness-core-test.el), `harness-tools-a-plugins-tools-are-for-the-sessions-naming-it`
(test/harness-tools-test.el) and `harness-tools-dev-repository-names-its-plugin`
(test/harness-tools-dev-test.el) hold this.

## Vendored libraries

A directory of `lisp/vendor`, `lisp/vendor/NAME/`, holds a library the
harness ships without owning it: laid out as the repository of its own it
can become (its source, tests, README and LICENSE), and written to work
without the harness.  The first is `compose-quote`, which the compose
box quotes with (see Compose box); the second is `change-review`, which
the changes of a task are reviewed with, in threads of comments (see
the review of a task's changes, under Presentation contracts), and
which reviews emailed patches as well.  lisp/vendor/README.md is the
guide; the contract is this:

- A library needs nothing of the harness and never mentions it: no
  `harness` name, no `(require 'harness-...)`, not in a comment or a
  docstring either.  The dependency runs one way.  What joins the two
  lives in the harness's own files, which set the library's variables
  and bind its commands: the compose box sets
  `compose-quote-source-function` to `harness-ui-markdown-source`, say.
  `harness-vendored-libraries-stand-alone` (test/harness-core-test.el)
  reads every `.el` file of every library for the word, and runs each
  of its `*-test.el` suites in an Emacs with only the library's own
  directory on `load-path`.
- harness.el puts each directory of `lisp/vendor` on `load-path` as it
  loads (`harness--vendored-directories`), and `harness--setup-load-path`
  does so again when the harness starts or reloads.  So any Emacs that
  loads harness.el finds the libraries: the tests, the harness process,
  and the update check of a harness older than this one, which loads the
  new harness.el before it compiles the new tree.  A running harness
  older than this one, reloading after an update, compiles every file
  with the `load-path` it has before it loads the new harness.el:
  harness-ui-compose.el therefore looks for `compose-quote` beside
  itself when `locate-library` does not find it.
- A library the harness needs at start is in `harness--library-files`
  (compose-quote is, and the four files of change-review -- the model,
  the diff, the mail and the UI -- after it, last): it loads compiled
  before any module, and
  `harness-reload` checks it compiles and loads it again.  One that is
  only on `load-path` loads from its source on its first `require` and is
  not reloaded.  `harness-auto-reload-mode` watches the directories.
- The update check (`harness--verify-program`) has the libraries'
  directories on its `load-path` and compiles every `.el` file of a
  library but its tests (`NAME-test.el`), reporting one by its path in the
  tree, so a library that does not compile refuses an update like any
  other file.  `scripts/lint.sh` does the same.
- `scripts/test.sh` runs `lisp/vendor/*/*-test.el` with the harness's
  suites, each in a clean Emacs with the harness loaded; a library's own
  `make test` runs its suite alone, as it will run in its repository.
- A library moves to a repository of its own with `git subtree split`
  and is taken from there with `git subtree add --squash`; later
  `git subtree pull --squash` and `push` keep the two together.  The
  steps that were tested, and the table recording each library's
  upstream and vendored commit, are in lisp/vendor/README.md.

## Data shapes

All shapes are keyword plists (the JSON convention in harness-util:
objects are plists, arrays are lists, `nil` is null, `:false` is false).
`harness-json-encode` gives bytes (unibyte UTF-8 since Emacs 30) for a
process, a file or an HTTP body; JSON that goes inside other text (a
prompt, a tool result) or inside other JSON comes from
`harness-json-encode-text`, since bytes there break the next encoding.
Symbols used as enum values travel as strings over the wire and are
interned back by the ACP layer for a fixed set of keys (`:status`,
`:permission-mode`, `:kind`, `:behavior`, `:scope`).

### Session

```elisp
(:id "uuid"  :name "short title or nil"  :kind main|fork|btw|subagent|internal
 :project "/abs/root/"  :cwd "/abs/dir/"  :host nil|"/ssh:user@host:"   ; TRAMP prefix
 :worktree nil|"/abs/worktree/"
 :model "PROVIDER:MODEL"            ; e.g. "claude:claude-fable-5-1"
 :permission-mode ask|accept-edits|auto|yolo
 :thinking nil|"low"|"medium"|"high"|"xhigh"|"max"
 :non-interactive nil|t             ; its own switch, from harness-non-interactive at creation
 :status idle|running|blocked|inactive
 :parent-id nil|"uuid"  :fork-node nil|"node-id"
 :created FLOAT  :updated FLOAT
 :last-message nil|FLOAT            ; when its latest user or assistant message was written
 :usage (:input N :output N :cache-read N :cache-write N :cost F :list-cost F :context N :turns N
         :last-output N                                         ; the output of the request :context sizes
         :stream-output N :stream-seconds F                     ; what its timed calls streamed: output tokens, seconds
         :billing api|subscription|extra-usage :plan "max"     ; billing and plan of the latest call
         :cache-at FLOAT :cache-model "ID" :cache-ttl N         ; the last request that used the prompt cache
         :cache-dropped FLOAT)                                  ; when a redaction dropped that cache, if it did
 :cache nil|(:at FLOAT :ttl N :expires FLOAT :model "ID" [:dropped FLOAT])  ; derived: when the prompt cache lapses, whose it is
 :context-window N                  ; in effect: the override, else the model's
 :context-window-override nil|N     ; a window set for the session
 :budget nil|(:amount F :hard BOOL)    ; given to the session; the Budget setting is not copied
 :head "node-id"
 :queue ((:id "q1" :text "…" :attachments (ATTACHMENT…)) …)
 :pending ((:id "p1" :kind permission|question :payload PLIST :created FLOAT) …)
 :todos ((:id :text :status pending|in-progress|done) …)
 :plan nil|"markdown"
 :provider-state PLIST                 ; owned by the provider it names: (:cli-session-id … :provider "claude")
 :provider-node nil|"node-id"          ; the node that provider conversation reached
 :move nil|(:cwd "/abs/new/" :project "/abs/root/" :keep-old-dir BOOL))  ; a move waiting for the turn to end
 :ext nil|PLIST                        ; settings other modules keep: (:supervisor t :supervisor-plans (…))
```

`:provider-state` is opaque to everyone but the provider that wrote it,
which it names as `:provider` (see "provider", Provider state): only
that provider's models continue it, and `session/provider-state` says
whether a given model can.

`:ext` is what modules that are not the session's own keep about it, a
plist of keyword to value (`session/set-ext`): the supervisor module's
`:supervisor`, `:supervisor-plans` and `:supervisor-write-up`, say.  A
value must come back from the record's JSON as it went in (`t`, `:false`
for an explicit off, a string, a number, or a list or plist of those) to
survive a restart.  It is stored with the record and never copied to a
fork: each module sets up its own forks.  Every change is announced as
`session/ext-changed`.  The redact module keeps `:redactions` there,
the records of the redactions that changed the session (the last 50; see
redact), and `:redaction-pending`, the labels and fingerprints of those
that wait for its running turn to end.

`:usage :context` is the input size of the last request (prompt tokens
incl. cache) and `:last-output` what that request wrote, which the next
one sends back: the conversation holds about the sum of the two, which
the UI shows as the context in use and colours against
`:context-window`.  While a turn runs, the usage module's live count
stands in for both and for `:output` (see "usage", Live token count).
`:cost` is what the session's calls were billed and `:list-cost` the
same calls at API prices (they differ when a subscription paid); see
"Usage record".

`:usage :stream-output` and `:stream-seconds` are the output tokens of
the model calls whose streaming the usage module timed and the seconds
the model spent streaming them, summed over the session's whole life
(`session/usage-note`; "usage", Output rate).  Output over seconds is
the session's average output rate, which waiting for a first token and
running tools do not dilute, where `usage/rate` averages only the
newest calls.  `session/usage-add` never writes them and keeps them as
it finds them; a session that streamed nothing measurable has neither
key.

`:last-message` is when the session's latest user or assistant message
was written (`session/append` sets it from the node's `:ts`).  Unlike
`:updated`, which moves with every change of any kind, it moves with
messages only, so a list can say how long ago anything was said.  A
hint, thinking, a tool call or result and a compaction leave it alone.
A record written before sessions kept it has none, and a reader falls
back on `:updated`.

`:kind internal` is the record of one model call the harness made on
its own, outside any turn (see `session/internal-start`).  It holds the
prompt as its one user message and the reply, when the call got one, as
its one assistant message, and has a model, usage and cost like any
session, but no temporary directory; the policy fixes none of its
settings and nothing can be sent to it.

`:cache` says when the session's prompt cache lapses, and whose it is.
A provider keeps the start of a conversation cached for a while after a
request read or wrote it (Anthropic five minutes or an hour, OpenAI
five to ten minutes, DeepSeek hours), and every such request keeps it
longer.  `session/usage-add` stamps `:usage` with when the last request
that used the cache was made (`:cache-at`, the request's own time when
the provider says it, else when its usage came), the model it was sent
to (`:cache-model`, the record's `:model`, else the session's) and the
lifetime the provider reported for it, if any (`:cache-ttl`); a request
that used no cache drops them, and a record without tokens (`:turns`)
leaves them.  They persist with the session, so a reloaded or resumed
session still knows.  Whether a request used the cache is for the
record's tokens to say (`:cache-read` or `:cache-write` above 0):
`:cache-at` is only when, so a record that names a time and counts no
cache token stamps nothing.  A hosted loop's turn is one record that
covers several requests, and its `:cache-at` is the time of the last of
them, the one that kept the cache longest: an older time would have a
cache that was just renewed look lapsed.  `:cache` is derived from them
each time the session is described, like `:context-window`: `:ttl` from
`provider/cache-ttl` for the stamp's model (the reported lifetime, else
the configured one), `:expires` = `:at` + `:ttl` and `:model` the
stamp's model.  Past `:expires` the next request sends the whole
context again at the uncached rate, which the chat warns about above
the compose box (`ui-cache`, see "Chat buffer").  A few seconds before
that moment the `cache` module says so (`cache/pre-expire`, see
"cache"), for whoever can use a cache that is still hot: to read it
once more, which restarts its lifetime ("cache-warm"), or to compact the
conversation in it ("cache-compact").

A cache serves the model that wrote it, no other.  A session switched
to another model keeps reporting the old model's cache, `:model` telling
it from its own: the new model reads none of it, so its first request
sends the whole context uncached at once, and switched back while the
cache lasts the session finds it warm again.  A step still sent to the
old model after a switch stamps that model's cache (the agent passes
the step's model).  Some changes start the conversation over instead,
so the next request sends none of the old one, cached or not, and
`:cache` is nil: a compaction, whose summary or transcript note
replaces the transcript (its usage record carries `:cache-reset`, which
drops the stamp whichever model summarised, a handoff's summary
included), and a model
whose provider keeps a conversation of its own and holds none of the
session's (a hosted loop it was switched to, lossily:
`session/provider-state` gives nothing for it), which is sent only the
newest messages and what a handoff gives it.  `:cache` is also nil for a session without
context (a new one never warns), before any request used a cache, and
after one that did not.

A redaction drops a cache too.  A hosted loop's provider keeps the
conversation and caches it; `session/reset-provider` drops that
conversation, and the next turn opens a new one with the redacted
transcript as text, a start the old cache does not hold (and could not
be used again if it did: it holds the secret).  The stamp cannot say so,
as it still names the last request and its lifetime, so the reset marks
the session's `:usage` with `:cache-dropped`, the moment (a float time),
when the session reports a cache (a stamp, and a context above 0), its
model is a hosted loop and no reset marked it since the last request
that stamped a cache (`session/reset-drops-cache-p` says whether a reset
would).  Then, while the stamp has not lapsed by itself, `:cache` ends
with `:dropped`, the same time, and its `:expires` is that time too: the
cold-cache gate (see cowboy), the seeds and the UI, which read
`:expires`, find the cache gone from the drop on, and `:dropped` tells
them why.  A cache that had lapsed before the drop is reported as it
was.  A session on a provider that is sent the whole transcript with
every request is not marked: its next request is built from the redacted
transcript and still reads the cache up to the first spot that was
redacted.  A request that stamps a cache, one that used none, and a
compaction (`:cache-reset`) clear `:cache-dropped`; a record without
tokens leaves it.

`:context-window` is looked up in the model catalogue (`provider/model`)
each time the session is described, so it follows the catalogue; only
`:context-window-override` is stored.  A copy of the catalogue's window
would go stale when the catalogue changes, or keep the estimate given
for a model whose provider has not answered yet.  When the
catalogue changes, the sessions whose window moved get `session/changed`.

### Node (conversation DAG)

```elisp
(:id "n-…" :parent "n-…"|nil :session "uuid" :ts FLOAT
 :kind user|assistant|thinking|tool-call|tool-result|hint|compaction|plan
 ;; user / assistant / thinking / hint / compaction / plan:
 :content "text"  :blocks (BLOCK…)          ; blocks only when non-text content exists
 ;; tool-call (:title from `harness-tool-title': the tool's label, then what the call is about):
 :tool "read_file" :call-id "toolu_…" :input PLIST :title "Read file: src/x.el"
 ;; tool-result (:images only when the tool returned pictures for the model to see):
 :call-id "toolu_…" :output "text" :is-error BOOL :attachments (ATTACHMENT…)
 :images ((:path "/abs/shot.png" :mime "image/png")…)
 :usage PLIST        ; assistant nodes: this response's usage
 :checkpoint PLIST   ; where a hosted provider's conversation stood after this node
 :meta PLIST)        ; anything else (model, duration, cost …)
```

A user message the user did not write says who sent it in its `:meta`
`:from`: `(:kind system :source "tasks")` for the harness itself, from
`harness-sender-system', or `(:kind session :id "uuid" :name "…")` for
another session's agent, from `harness-sender-session' (name as it was
then).  No `:from` means the user; read it with `harness-node-sender'
and `harness-sender-kind' (harness-util, both sides of ACP), which
tolerate a kind that travelled as a string.  The model still gets the
message as a user message; UIs show the sender instead of "You".

A tool call and its result can be the harness's as well: the merge
queue shows the session it starts to resolve a child's conflicts as a
`spawn_agent` call in the child (see merge).  Both nodes carry the
sender in `:meta` `:from`, which `harness-outside-node-p` checks, and
the session the call stands for in `:meta` `:child-id`; the result of
the model's own `spawn_agent` names its sub-agent the same way.  The
model never made such a call, so `session/messages` leaves the call and
its result out (a steering message recorded after one goes out with the
next node the model sees), and so does a handoff: its transcript, its
check for history and what a hosted loop missed.  The chat shows the
call as its sender's, not the agent's, with a link to the session,
running until its result comes.

A node the harness wrote to hand the conversation over to a model of
another provider (see "handoff") says so in its `:meta` `:handoff`,
`(:mode "transcript"|"compact" :file PATH :from MODEL :to MODEL)`: the
user message pointing the new model at a transcript file (sender
`(:kind system :source "model handoff")`), or the compaction node of a
summary made for it.  Read it with `harness-node-handoff`.  The chat
shows the note as the harness's, with the two models and a button that
opens the file.  An assistant or thinking node's `:meta` `:model` is
the model of the step that wrote it, which a switch during that step
does not change.

A hint the perms module writes after a lasting answer to a permission
request (allow or deny for the session, or always) says what the answer
recorded in its `:meta` `:permission`: `(:scope session|always :rule
RULE :undo offered)` for a rule, `(:scope session|always :dir DIR :undo
offered)` for a directory granted.  After an undo, `:undo` is `undone`,
`changed` or `gone`, and `:result` is the message it gave.  No `:undo`
means the answer recorded nothing new.  Read it with
`harness-node-permission` and `harness-permission-undo-state`
(harness-util), which tolerate the symbols that travelled as strings.
The chat shows the note's text with an [Undo] that calls
`permission/undo` (see perms) while `:undo` is `offered`.

A lasting decision (see "decisions") is named by the notes about it.
The hint written where it was made -- a lasting permission answer's,
or the cold-cache hint of an "always" answer (see cowboy) -- has its id
in its `:meta` `:decision`; a hint or a tool result written later where
it took effect, in any session, has it in `:meta` `:decided-by`: the
cold-cache hint of the default taken unasked, the result of a call a
recorded rule denied.  Read them with `harness-node-decision` and
`harness-node-decided-by` (harness-util).  The chat draws each such
note's [Undo] or [Redo] from the decision itself (ui-decisions), not
from the node, so a move made in one session shows in all of them.  A
permission note keeps `:permission` `:undo` in step with its decision
(`offered` while done, `undone`, `changed` or `gone` after a move), for
a client that does not follow decisions.
A tool-result node whose output had secrets masked (see secrets) says so
in its `:meta` `:masked`, a list of `(:label LABEL :fingerprint F
:count N)`: which secret, by the first 8 hex digits of its SHA-256, and
how often, never the text around it.  A hint the redact module writes
after taking a secret out of a session (see redact) is plain text in
`:content`: the labels and fingerprints, where the secret was found, at
whose request and why.

A hint that has the same kind of thing to say again and again keeps the
lot in one hint rather than a hint each (tool-slots-load does, for the
tool slots a busy machine takes away and gives back).  Its `:meta`
`:fold` is `(:key KEY :title TITLE :items ((:ts TIME :text TEXT) …))`:
KEY names the module that writes it, which finds the hint again to add
to it, TITLE is what the hint says while it is folded, and ITEMS are
the lines under it, oldest first.  Read it with `harness-node-fold`
(harness-util), which tolerates what travelled over JSON.  `:content`
says the same in plain text, the title and then a line to an item, for
a client that does not fold; with one item it is that item's text, so a
hint of one line is the note it would have been.  The module adds a line
with `session/update-node`, which announces the hint again
(`session/node-updated`).  Hints are not sent to a model
(`session/messages` leaves them out), so a hint changing where it
stands changes nothing a model is sent.

A session's transcript is the path root → `:head`.  A fork copies the
ancestor chain (same node ids) into the new session and records
`:parent-id` / `:fork-node`, so the tree view can merge families by id.
A tool call the fork copies without a result gets one of the fork's
own, after the copied nodes (`:meta (:forked t)`).  That happens when
the parent is mid-turn, as with `spawn_agent` forking it, or when its
head was moved back between a call and its result.  The result goes
to the parent, never to the fork, and providers that pair calls with
results (DeepSeek and other strict OpenAI-compatible servers, Bedrock)
reject a request with an unanswered call.

A hosted-loop provider (Claude Code, Copilot) holds the conversation
itself and only gets new user content each turn, so its conversation
and the transcript must agree.  `:checkpoint` is opaque provider data
saying where that conversation stood once the node's content was in it
(for Claude Code `(:cli-session-id ID :uuid UUID)`, the CLI session and
the entry of its chain holding the node).  `:provider-node` is the node
the session's provider conversation reached: the head when its last
turn ended.  When the head is not at or after it (checked out at an
earlier node, or on another branch), the next turn first cuts the
conversation at the last checkpoint on the head's path, or starts a new
one, seeded with the transcript, when there is none
(`session/provider-continuation`, `harness-agent--follow-head`).  A fork
at an earlier node does the same for its first turn.  Either way the
model never knows what came after the node.  A session from before
`:provider-node` is taken to be where its conversation is, unless its
head has a later node of its own (it was moved back) or it is a fork
made at an earlier node of its parent, when the old forks got the
parent's whole conversation; such a session starts a new one.

### Content blocks (provider messages, prompts, attachments)

```elisp
(:type "text" :text "…")
(:type "image" :mime "image/png" :data "BASE64")            ; or :path "/abs" (read lazily)
(:type "audio" :mime "audio/wav" :data "BASE64")
(:type "file" :path "/abs/f" :size N :mime "text/plain")     ; reference only
(:type "thinking" :text "…" :signature "…")
(:type "tool_use" :id "…" :name "…" :input PLIST)
(:type "tool_result" :tool_use_id "…" :content "…" :is_error BOOL)
(:type "tool_result" … :images ((:type "image" :mime "image/png" :path "/abs")…))  ; or :data BASE64
```

ATTACHMENT = `(:path "/abs" :size N :mime "…" :name "display")`.

A tool_result's `:content` is always a string, so everything that reads
the words of a conversation (a summary, a title, the judge) is
unaffected by its `:images`.  `session/messages` gives the block the
images with their `:path`; the agent makes them `:data` when the request
goes out, for a model that reads images, and drops them with a note in
the text for one that does not (see agent).

### Usage record

`(:input N :output N :cache-read N :cache-write N :cost F :list-cost F
:billing api|subscription|extra-usage|nil :plan ID :model "ID"
:cache-at FLOAT :cache-ttl N :cache-reset BOOL)`; amounts in USD.

- `:cost` is what the call was billed.  `:list-cost` is the call at
  API list prices.  They are the same unless a subscription paid.
- `:billing` says who paid:
  - `api`: per token, through an API key, a bearer token or a cloud
    provider.
  - `subscription`: a plan such as Claude Max paid, so `:cost` is 0.
  - `extra-usage`: the plan's extra usage, billed at API prices.
  - nil: the provider did not say; it reads as per-token billing.
- `:plan` is the subscription's id, such as "max".
- `:cache-at` and `:cache-ttl` are optional: when the request that read
  or wrote the prompt cache was made (a float time; the last request's,
  for a record that covers several) and the seconds the provider said
  it keeps that cache.  Claude Code gives both: the time of the turn's
  last main-conversation request -- its `message_start`, else its first
  assistant message when the CLI prints no partial messages -- whatever
  that request's own usage says of the cache (Bedrock and gateways
  stream the cache fields late or not at all, and the time of an earlier
  request that said more would make a warm cache look old), and 3600 or
  300 by whether the request wrote to the one-hour or the five-minute
  cache.  A sub-agent's requests use a cache of their own and a request
  the CLI makes between turns belongs to no turn: neither counts, and a
  turn starts without a time.  Whether the record used the cache is for
  its tokens to say, not for `:cache-at`: the session stamps only a
  record with `:cache-read` or `:cache-write`.  Without them the
  record's own arrival stands for the time, and the configured lifetime
  for the TTL (see "Session" and `provider/cache-ttl`).
- `:model`, optional, is the model the request was sent to, which a
  step that ends after a switch tells from the session's; the cache the
  request used is that model's.  `:cache-reset`, optional, says the
  conversation starts over (a compaction's summary replaces it): the
  record drops the session's cache stamp instead of setting it.  Any
  record that changes the stamp also clears the session's
  `:cache-dropped`, the moment a redaction dropped the cache, which is
  not a key of a record (see "Session").
- `:context`, optional, is the prompt size of the record's last
  request, which replaces the session's.  With it the session's
  `:last-output` becomes the output of that request: the record's
  `:last-output` when it covers several requests (a hosted loop's
  turn), else its `:output`.  A compaction's record says 0: the summary
  is all the conversation holds.

When a provider reports no cost, `session/usage-add` prices one from the
model catalogue.  A missing list cost is the cost, or priced too when a
subscription paid.  Budgets count `:cost`, so usage a plan covers spends
none of them.  `harness-billing-of`, `harness-usage-list-cost`,
`harness-usage-covered` and `harness-format-spend` (harness-util) read
these keys on either side of ACP.

## Module contracts (state layer)

### config

Layered settings: directory `.dir-locals.el` (most specific) →
project-root `.dir-locals.el` → customize default.  Above them all is
the policy (lisp/harness-policy.el, [policy.md](policy.md)): an option
an administrator's policy file sets has the policy's value, for every
option and not only the layered ones, and no layer changes it.  Variables are
`defcustom`s with `:safe` predicates so dir-locals never prompt:
`harness-model` (default "claude:claude-fable-5-1"),
`harness-permission-mode`, `harness-thinking`, `harness-btw-thinking`
(the level BTWs start at, default "low", fitted to the levels their
model offers; nil for the session's),
`harness-btw-model` (the model BTWs run on: `auto`, the default, is the
simple tier of the provider of the model they would otherwise use; a
`PROVIDER:NAME`; nil for that model itself),
`harness-allowed-directories`, `harness-sandbox-policy`,
`harness-non-interactive`, `harness-supervisor`,
`harness-commit-msg-strip-attribution` (see commit-msg).  A module
defines some of them, `harness-supervisor` the supervisor module and
`harness-commit-msg-strip-attribution` the commit-msg module: until it
is loaded the key takes part in nothing, and every reader of the layers
skips it (`harness-config--layered-keys`).  `harness-budget` has a
global value only: it is one budget for all sessions together (see
usage).

The other harness options (the `harness` customize group, less the
ones that decide how the harness starts or reaches the UI:
`harness-process`, `harness-state-directory`, the module directories
and lists (`harness-extra-module-directories` among them), the
`harness-server-*` and `harness-acp-*` options, minor modes, and less
`harness-corporate-mode`) have a global value only.  `config/set` and
`config/unset` refuse the ones of `harness-config-hidden-options`,
`harness-corporate-mode` among them, as set in the init file only (or
by a policy, which is how an administrator forces corporate mode on).
Options named `...-api-key`, `-token`, `-secret` or `-password` are
secrets: their values never leave the harness and never go to a
`.dir-locals.el`.

Where an option holds records (the provider endpoints, Bedrock's
per-model defaults, the standing permission rules, a model plist), its
customize type names the keys of the record in `:options`: each key
with a `:tag`, a value type of its own, a `:doc`, and the `:value` it
starts from.  (`harness-provider.el` holds the shared model, price,
modality and thinking-level types; `harness-provider-model-type` adds
a provider's own keys to the model type.)  Keys the type does not name
stay matched, as `plist` does, so a record written in Lisp is never
refused for having an extra key; the settings page draws them last, to
be removed.  A key that names a value type the value does not fit is
refused on save, where a free-form plist would have taken it.

`harness-config-sections` names the options most people change, in
sections by what they are for (new sessions, supervisor mode, files and
safety, task board, commits, notifications, models and services);
`config/describe` lists them first, each with its `:section`, then the
advanced ones.  A setting a page should not lead with but must keep
working stays a global `defcustom` and is advanced; what only the
harness's own code has an opinion about is a `defconst`/`defvar` named
`MODULE--thing`.
See docs/configuration-audit.md for the rule and the audit behind it.

- `config/get KEY CWD` → value for a session at CWD (KEY is the symbol
  or its name; layered settings only); the policy's when it sets KEY,
  whatever the dir-locals files say.
- `config/set KEY VALUE &key scope cwd printed` — scope
  `directory|project|global`; default: project if a project is found,
  else directory, and global for an option that does not layer.
  `:printed t` says VALUE is the value printed with `prin1`, which is
  how a JSON client sends symbols and lists.  The value must fit the
  option's customize type, and a directory-local one its `:safe`
  predicate.  Persists with `add-dir-local-variable` (no backup file
  is left behind), or for `global` with `harness-save-user-option`,
  which asks the UI's Emacs to `customize-save-variable` (its custom
  file).  An option the policy sets is refused at every scope ("KEY is
  set by policy (FILE) and cannot be changed"), and nothing is written.
- `config/unset KEY &key scope cwd` — removes KEY from that layer: a
  `project` or `directory` scope deletes it from the `.dir-locals.el`
  (and the file once nothing is left in it); `global` sets the option
  back to its standard value.  Refused as `config/set` refuses.
- `config/layers CWD` → `((policy . V) (global . V) (project . V)
  (directory . V))` for display; `policy` lists the keys the policy
  sets, and the dir-locals layers what their files say, even where the
  policy overrides it.
- `config/describe CWD` → `(:cwd :root :project :in-project :files
  :policy :modules :settings)` for a settings page: every option, layered ones
  first, each with its doc, customize `:type`, module, `:standard`,
  `:global`, `:project`, `:directory` and effective `:value` with the
  `:source` layer it comes from, plus the layers whose value does not
  fit the type (`:invalid`).  Types and values are printed (`read`
  them back), so they survive JSON; an unset layer is null, one set
  to nil is `"nil"`.  A secret has `:has-value` instead of values.
  A setting the policy sets is `:locked`, its `:source` is `policy`,
  its `:value` the policy's, and it is not `:editable`.  `:policy` is
  null without a policy, else `(:file FILE :settings ((:key :value
  :listed :defined) ...))`: every option the policy sets, in its order,
  with whether the page lists it (corporate mode is not listed) and
  whether this harness defines it at all.
- `config/overrides KEY &key value printed dirs` → `(:key :value :tasks
  :files)`: what keeps a global value of layered KEY (VALUE, printed
  when `:printed`, by default the global value itself) from applying.
  `:files` lists the `.dir-locals.el` files, as `(:file :scope
  project|directory :dir :project :value)`, that set KEY to another
  value, at the project or the directory layer of where work goes on
  now: the active sessions, the current tasks and their sessions
  (`session/select` with `:tasks`), and DIRS (a task board's, say).
  A linked git worktree's file (a task's, say) that sets KEY as the
  file at the same place in its main checkout
  (`harness-files-main-checkout`) does is the project's checked-in
  copy: the entry names the main checkout's file and project, the one
  to change, once for all the tasks.  A worktree whose file says
  something else, a task's edit, say, is named itself.
  `:tasks` is the task default that wins over KEY for new tasks
  (`harness-tasks-model` for `harness-model`, and so on) when it is set
  to another value, else nil.  Remote and missing directories are
  skipped, values are printed, and nothing is ever written: the
  all-sessions commands report it after changing a default.
- Event `config/changed KEY VALUE SCOPE CWD` after a set or unset;
  after an unset VALUE is the value now in effect at CWD, and for a
  secret it is nil.

### project

- `project/root CWD` → root directory (project.el, falling back to CWD).
- `project/name ROOT` → display name.
- `project/mains ROOTS` → one `(:root ROOT :main MAIN)` for each absolute
  directory name in ROOTS, in order (anything else is left out): the main
  checkout the work in ROOT counts for (`harness-project-main`).  A linked
  git worktree, such as a task's or a sub-agent's, is of the checkout it
  was made from, wherever it is and also once it is gone from disk,
  which for one made beside its checkout, in `NAME-worktrees` (the
  layout before `.worktrees`), the checkout beside it says
  (`harness-files-owning-checkout`); any other directory is its own.  A
  scratch directory, one in a session's temporary directory
  (`harness-UID/ID` where temporary files go: `harness-files-scratch-owner`),
  is no checkout: an agent made it for the session of that id, say as
  the working directory of a sub-agent, so its work counts for that
  session's project, followed through scratch directories of scratch
  directories, and for none, with `:main ""`, once that session is gone.
  It reads `.git` files and runs no process, so a client such as the
  phone app asks about every directory its sessions and tasks work in,
  and the ones the harness lists, at once, to fold the worktrees of a
  project into it: a project is a main checkout, and a session started in
  a worktree has that worktree as its `:project`.
- `project/files ROOT &optional QUERY LIMIT` → promise of relative paths,
  fuzzy filtered; nil outside a project.  Never blocks: projectile's
  cache when it has the project, else an asynchronous listing
  (projectile's command, or `git ls-files`) stored back into projectile's
  cache.  No cache of its own.  Implemented by lisp/harness-files.el.

### store

Persistence under `harness-state-directory`:
- `store/save NAME OBJ`, `store/load NAME` (JSON files, atomic write).
- `store/append NAME OBJ`, `store/read-all NAME` (JSONL).
- `store/sqlite &optional NAME` → open built-in sqlite handle for
  `NAME.db`, `usage.db` by default (nil when Emacs lacks sqlite; callers
  fall back to JSONL).  One handle per database, kept open; a handle of
  another state directory is closed first.  `store/sqlite-close
  &optional NAME` closes one.  The session search keeps its index in
  `search.db` this way (see session-search).
- `store/list PREFIX` → names.

### session

Owns session records, nodes, status, queue, pending requests, persistence
(sessions/ID.json + sessions/ID.nodes.jsonl).

Restarts: records are written shortly after a change, at once when the
status changes, and all of them on exit; nodes are appended as they
come.  Every session loads `inactive` (closed until something resumes
it).  One saved `running` or `blocked` was interrupted mid-turn by a
harness that stopped, so loading settles it: each tool call without a
result gets one (`:is-error t`, `:meta (:interrupted t)`) and a hint
says what it was doing or which question it waited on.  So does a call
the harness recorded for it in its parent (`harness-outside-node-p`,
with its id as `:child-id`: the merge queue's conflict resolver), which
nothing else would answer; the parent need not have been running.  Only calls
from the last compaction on count, as for forks: earlier ones reach no
provider, so a result for one would answer nothing.  Pending
requests are not restored: the turn that would read their answers is
gone.  A message one held back from a turn that had not started (its
payload's `:waiting-message` `(:text :from)`: the cowboy module's
question about a cold cache) goes back in the session's queue, with
its sender, and the hint says so (`harness-session--requeue`).
`session/interrupted` returns what the load settled, oldest first, one
`(:id :status :pending :calls :text)` per session: the status it was
saved with, the pending requests it waited on, the tool calls the load
answered (`(:tool :call-id)`) and the hint's text.  The resilience
module carries those sessions on (see resilience).

The node log is only ever appended to, but for a redaction, which
replaces it whole (`session/redact-text`, `session/reset-provider`; see
redact).

- `session/create &rest PLIST` — `:cwd` required; `:name :model
  :permission-mode :thinking :kind :parent-id :host :worktree`,
  `:context-window` to set the session's own window and
  `:context-window-limit` to cap its model's window at a number of
  tokens (see the compaction section), `:ext` to give it the settings of
  modules that keep some (see `session/set-ext`).  Fills
  project, defaults from `config/get`.  A `btw` session without
  `:model` runs on `harness-btw-model` applied to `harness-model` as
  configured at its `:cwd` (`harness-session--btw-model`: by default
  the simple tier of that model's provider, the model itself when the
  provider names none), unless the policy fixes `harness-model`.  A
  `btw` session without `:thinking` takes `harness-btw-thinking` fitted
  to the thinking levels the catalogue lists for its (final) model in
  `:thinking-levels` (`harness-session--btw-thinking`, by
  `harness-thinking-level-fit`): that level when the model offers
  it, else the strongest level it offers below it, else its weakest;
  only with no level configured (nil), or a model whose catalogue lists
  none, does it take `harness-thinking`.  → session.  Event
  `session/created ID SESSION` fires once the record is stored.  A
  subscriber may change the session meanwhile (the supervisor module
  sets its `:ext`), so `session/create` announces (`session/changed`)
  and returns the session as the `session/created` subscribers left it,
  not as it was when they were told: its maker and the UIs see what
  they set, from the start.
- Settings a policy fixes ([policy.md](policy.md)): when the policy sets
  `harness-model`, `harness-permission-mode`, `harness-thinking` or
  `harness-non-interactive`, every session's copy is the policy's value
  (`harness-session--policy-options`; a BTW's thinking aside, which
  follows `harness-btw-thinking`.  Its model is not aside: a policy on
  `harness-model` fixes a BTW's model too, so it runs on the policy's
  model, not the simple tier, and `harness-btw-model` changes nothing).
  `session/create` and `session/fork` give it whatever PLIST asks for,
  a record loaded from disk gets it, and a reload (`harness/reloaded`)
  brings every session in line with the policy as it is then, with
  `session/updated`.
  `session/update`, `session/set-all` and the task board refuse another
  value with "OPTION is set by policy (FILE) and cannot be changed",
  changing nothing; `harness-session-check-policy` is the check, which
  also refuses a model `harness-allowed-models` does not allow.  An
  internal session is the exception: the policy fixes none of its
  settings, so it keeps the model its call was made with.
- `session/get ID`, `session/list &optional FILTER` (`:project :status
  :kind :parent-id :active :ids`; `:ids` is a list of session ids, and
  only the sessions it names match, nil or no key matching every
  session as the other keys do), `session/delete ID` (its temporary
  directory goes too).
- `session/tmp-dir ID` → the session's own temporary directory, made if
  missing, or nil.  Every local session but an internal one has one:
  `harness-UID/ID/` in `temporary-file-directory` (`/tmp/harness-1000/ID/`;
  the internal `harness-session--tmp-root` moves the root, which the
  tests do).  It is made with the session (mode 700, as is the root),
  made again whenever it is asked for and missing (a reboot empties
  /tmp), and deleted with the session.  Being made when asked for is the
  point: callers ask right before they rely on it.  /tmp is shared, so
  only a real directory of the user's own, in a root of the user's own,
  is handed out; a symbolic link or somebody else's directory gives nil
  and one warning in the log.  Remote sessions have none (nothing is
  made on their host).  The perms jail lists it (source `tmp`), bash
  binds it writable in the sandbox, and the system prompt and
  `session_info` name it.
- `session/update ID &rest PLIST` — settings and name; appends a `hint`
  node ("model → …") and persists the setting through `config/set` when
  `:persist t`.  `:context-window N` sets the session's own window, nil
  its model's again; a new `:model` drops a window set for the old one
  unless PLIST sets one too.  `:context-window-limit N' caps its
  model's window at N tokens, nil the model's again, a
  `:context-window' set for the session winning over it.  Event
  `session/updated ID CHANGES`.
- `session/select &optional FILTER` → the session plists FILTER selects,
  newest first: `session/list`'s filter plus `:except` ids, and `:tasks`
  non-nil to add the sessions of the current tasks of every project
  (`task/session-ids`), even an inactive one a task goes on in, and to
  leave out those of completed tasks, the board's done column
  (`task/session-ids` with `:columns '("done")`), an active one
  included: a bulk change must not reach a task that is over.  `:ids`
  limits even the sessions `:tasks` adds: one it does not name is never
  selected, which is how the session list changes exactly its marked
  sessions.  An internal session is selected only when `:kind` asks for
  `internal`, even when `:ids` names it: it records a call and goes on
  with nothing, so a bulk change has nothing to do there.  It is the
  selection of `session/set-all`, `priority/set-all`,
  `supervisor/set-all`, `handoff/check-all` and `handoff/switch-all`.
- `session/set-all SETTINGS &optional FILTER` — the same change on every
  session FILTER selects (`session/select`); returns the ids that
  changed, newest first.  A session already holding the value is
  skipped, compared by `harness-setting-equal-p` (in harness-util: a
  false or absent `:non-interactive` is off, a permission mode's name
  is the mode), and each one changed gets the same event and hint as
  `session/update`.  This is what `harness-set-model-all` uses to move
  every session to another model or provider at once, when no session
  would lose its conversation (else `handoff/switch-all`), and what
  `harness-set-thinking-all`, `harness-set-non-interactive-all` and the
  `set_non_interactive` tool use, with `(:active t :tasks t)`; the
  session list's setting commands send `(:ids MARKED-IDS)` instead, to
  change the marked sessions and no others.
- `session/move ID DIR &rest OPTIONS` — moves ID to the working
  directory DIR, and with it to DIR's project, which the session list
  files it under: for a session started in one directory that works on
  another.  DIR is absolute or relative to the cwd, and on the
  session's host (a remote session's local names are on its host, where
  `~` is refused).  OPTIONS: `:keep-old-dir` grants the old cwd to the
  session (`:allowed-dirs`); `:project` names the root to file it under
  instead of `project/root`'s (the UI passes the one it sees, as for
  `session/new`).  Grants written relative to the cwd keep naming what
  they named.  The provider state goes: the Claude Code CLI keeps its
  conversations per directory and cannot resume one elsewhere, so the
  next turn starts a new provider conversation, which gets the
  transcript; a hint says so.  A session running a turn moves when the
  turn ends (`agent/turn-ended`): its provider process and system
  prompt stay in the old directory until then.  The record keeps the
  move as `:move` meanwhile, so a harness that stops first makes it as
  it loads the session, and moving the session back to where it works
  cancels it; a move that cannot be made any more by then is dropped
  with a hint.  Refused (`harness-error`): a session in a worktree, whose
  branch merges back through the merge queue; a directory on another
  host, or that is no directory; the directory it works in, with no
  move waiting; and whatever a module vetoes through the sync filter
  `session/before-move` (value `(:proceed t)`, arguments the session
  plist and the new directory; a veto returns `(:proceed nil :reason
  WHY)`).  The tasks module vetoes a task's session (the board follows
  the task's work in its directory), the merge queue a session that
  queued branches are to merge into or that resolves a merge's
  conflicts.  → the session, with `:move` while it waits.  Events
  `session/updated ID (:cwd :host :project :allowed-dirs)` and
  `session/moved ID OLD-CWD NEW-CWD` when it moves.
- `session/move-check ID DIR` → how ID would move to DIR, or the error
  `session/move` would signal; nothing changes.  `(:id :name :cwd NEW
  :host :project :old-cwd :old-project :defer BOOL :cancel BOOL)`:
  `:defer` says the move waits for a turn to end, `:cancel` that NEW is
  where ID works and the move only cancels the one it waits to make.
  What the `session_move` prompt says (see perms).
- `session/provider-state ID &optional MODEL` → the provider state of
  ID that MODEL (default the session's model) can continue, or nil.  A
  state belongs to the provider it names (`:provider`); a model of
  another provider gets nil, as if the session had none.  A state
  written before states named their provider belongs to the provider
  that answered last (the `:meta` `:model` of the newest assistant or
  thinking node), else to the session's model's: another provider
  having answered since means the state's own never saw those turns.
  The record itself is not changed.
- `session/set-status ID STATUS`.  Event `session/status ID STATUS`.
- `session/resume ID` (loads nodes, status idle), `session/deactivate ID`
  (closed: still listed and readable; the next message sent to it resumes it).
- `session/internal-start &rest PLIST` → the id of a new internal
  session, running: the record of one model call the harness makes on
  its own, outside any turn (the permission and Elisp judges, the
  session judge, a session's name, a recap, the Insights summary, the
  pet, the task board's search).  The provider module starts it for a
  request that names its job (`provider/complete`, "provider").  PLIST:
  `:job` (a few words, "Permission judge"; it names the session, and is
  "Internal call" when blank), `:model` (the model asked), `:prompt` (a
  user message marked as sent by the harness, `harness-sender-system`
  with the job, cut at 20000 characters with a note saying how long it
  was), `:parent-id` (the session the call is made for, kept only when
  that session exists; the call is listed under it), `:cwd` and `:host`
  (default the parent's, else `harness-state-directory`) and `:project`
  (default the parent's, else the one of its directory, a directory of
  `harness-state-directory` being a project of its own rather than part
  of the one around it).  The session is `kind internal` with status
  `running`, and starting it deletes the oldest internal sessions that
  are not running until at most 100 remain (the internal variable
  `harness-session--internal-keep`, not an option), so a call still
  under way keeps its session.  An internal session has no temporary
  directory, the policy fixes none of its settings, it is never named,
  governed by the supervisor or recapped, `agent/prompt` refuses it (it
  cannot be continued), and `session/select` and `session/tree` leave
  it out.
- `session/internal-finish ID &rest PLIST` → ID, nil for a session that
  is gone (it never signals for one): records how the call ended.
  PLIST: `:reply` (the text the model wrote, appended as an assistant
  message unless empty), `:stop-reason` (a symbol or its name) and
  `:error`.  A call that ended in `error` or was `cancelled` gets a hint
  saying so, with the error.  The session is then idle.
- `session/fork ID &rest PLIST` — copies the ancestor chain up to
  `:node` (default the head; ID's head never moves); `:kind
  fork|subagent`, `:name`, `:cwd` (defaults to parent's).  Each copied
  tool call without a result gets one in the fork.  It is an error
  result, `harness-session-forked-output`, saying the session was
  forked before the call returned and its result went to ID.
  `:call-id` names ID's call that forks it to start a sub-agent
  (spawn_agent passes its own).  That call's result is no error:
  `harness-session-spawned-output` tells the fork it is the sub-agent
  the call started, that its task is the next message, and that its
  final message is what the call returns.  Settling keeps the whole
  transcript, the current turn included; trimming back to the last
  finished turn or step would drop the context a fork is for: the
  request being worked on, the reasoning and the results already in.
  Asks the provider to fork its state via `provider/fork` when
  supported: at the parent's head (when that is where its provider
  conversation is) the whole state, at an earlier node the state cut at
  the last checkpoint up to it, and none when no checkpoint precedes
  the node, or when the fork's model is of another provider, which
  cannot continue the parent's state (`session/provider-state`).
  Without a forked state the fork has none, never the parent's own,
  which would carry on the parent's provider conversation; the provider
  then starts a new one from the transcript.  The fork's
  `:provider-node` is the node.  → new session.
- `session/btw ID &optional NAME MODEL`: a BTW side conversation over
  ID, a new, empty `btw` session sharing nothing with ID or with any
  other BTW (no nodes, no fork node, no provider state, no directory
  grants).  It takes ID's cwd, project, host, worktree and permission
  mode; `:parent-id` is ID only so lists show it under ID.  Its model is
  not ID's: a BTW is a quick question on the side, so it runs on
  `harness-btw-model` as configured at ID's cwd (`harness-session--btw-model`;
  `auto`, the default, is the simple tier of the provider of ID's model
  via `provider/tier-model`, ID's model itself when the provider names
  none; a `PROVIDER:NAME` forces that model, which the log notes and
  ID's model replaces when `harness-allowed-models` leaves it out; nil
  keeps ID's).  MODEL, a `PROVIDER:NAME`, is the per-BTW override: it
  wins over the setting for this BTW alone (blank is none), is checked
  with `harness-session-check-policy` (an error when the policy fixes
  another `harness-model`, or `harness-allowed-models` leaves it out),
  and is chosen once, at the start: from then on the BTW is a session
  like any, whose model `session/update` can switch.  A policy on
  `harness-model` fixes the BTW's model too.  It thinks at
  `harness-btw-thinking` as configured at ID's cwd ("low" by default, so
  quick questions get quick answers), fitted to the levels the catalogue
  lists for its own model (`harness-thinking-level-fit`, the rule
  Copilot's and Bedrock's efforts are fitted by too): that level
  when the model offers it, else the strongest level it offers below it
  (a DeepSeek model, which lists low, high and max, thinks at low for
  medium), else its weakest.  So a BTW that stays on ID's own model
  thinks no harder than the model has to, whatever ID's level is.  Only
  where nothing is fitted -- no level configured (nil), or a model whose
  catalogue lists no levels -- does it start at ID's level, which it
  keeps only if its model is ID's or lists it too, else at
  `harness-thinking`.  Over the wire it is
  `_harness/session/btw {id, name, model}`, `model` sent only when one
  was chosen.  Returns the new session.
- `session/nodes ID &optional (:limit N :before NODE-ID)` → path nodes,
  oldest first; `session/node ID NODE-ID`; `session/tree ID` → every
  node of the family (session + ancestors + forks) as a list with
  `:session` set, plus `:sessions` summaries.  The internal sessions
  made for a member of the family are left out of it, except the
  session asked for itself: they share no node with the conversation.
- `session/append ID NODE` → node with id/ts/parent filled; advances head.
  A `user` or `assistant` node (`:kind` a symbol or a string) also sets
  the session's `:last-message` to the node's `:ts`; no other kind does.
  Event `session/node-added ID NODE`.
- `session/update-node ID NODE-ID PLIST` (tool result streaming, titles).
  Event `session/node-updated ID NODE`.
- `session/set-head ID NODE-ID` — time travel: the next message
  continues from NODE-ID, with a provider conversation cut to match (see
  "Node").  Refused while ID runs a turn.  Event `session/head-moved ID NODE-ID`.
- `session/discard-nodes ID NODE-IDS` → the ids actually removed.
  Removes the named nodes wherever they are; a kept node whose parent
  went is re-parented to the last kept ancestor before it, so the
  transcript stays one chain, in memory and loaded again (the removal is
  written to the node log and the re-parenting with it).  The head moves
  to the newest node kept.  Events `session/nodes-removed ID NODE-IDS`,
  and `session/head-moved ID NODE-ID` when the head moved.  The agent
  uses this to drop the partial answer of a step it is about to try
  again (see agent, retry); a UI shows what went by reloading the head's
  path.
- `session/set-provider-state ID STATE`.  Event
  `session/provider-state-changed ID STATE` when STATE differs from the
  one held, so a provider whose live process holds the old conversation
  lets it go.
- `session/set-provider-node ID NODE-ID` (the agent, when a turn ends);
  `session/provider-continuation ID &optional NODE-ID` → `(:mode
  current)`, `(:mode checkpoint :checkpoint CP :node ID)` or `(:mode
  fresh)`: how the provider conversation goes on from NODE-ID (default
  the head).
- `session/hint ID TEXT` → appends hint node.
- `session/queue ID TEXT &optional ATTACHMENTS FROM` (FROM, when
  non-nil, is who sent it, not the user: the item keeps it as `:from'),
  `session/queue-update ID QID TEXT`,
  `session/queue-remove ID QID`, `session/queue-take ID &optional QIDS`
  → the items taken, in queue order, removed from the queue: all of
  them, or with QIDS (a list of item ids, or a vector) only those, the
  others staying queued.  Event `session/queue-changed ID ITEMS` (what
  is left).
- `session/pending-add ID REQUEST` → id; `session/pending-resolve ID PID ANSWER`;
  `session/pending ID`.  Event `session/pending-changed ID ITEMS`.
  Status becomes `blocked` while anything is pending.
- `session/usage-add ID USAGE &optional CONTEXT` → accumulated usage.
  A record of a request that read or wrote the prompt cache (its
  `:cache-read` or `:cache-write` above 0) stamps the totals'
  `:cache-at`, `:cache-model` and `:cache-ttl`, the record's `:cache-at`
  being only when; one that used none, or one with `:cache-reset` (a
  compaction), clears them (see "Session").  Each also clears
  `:cache-dropped`, which a redaction set (`session/reset-provider`).
  Event `session/usage ID USAGE-TOTAL RECORD`.  It keeps
  the totals' `:stream-output` and `:stream-seconds` as it finds them.
- `session/usage-note ID RECORD` → the totals (nil for a session that is
  gone): adds RECORD's `:stream-output` and `:stream-seconds`, the
  output tokens of model calls whose streaming was timed and the
  seconds they streamed, to the totals' keys of the same names, and
  nothing else of RECORD.  The usage module calls it for every call it
  measures ("usage", Output rate).  Unlike `session/usage-add` it
  records no usage row and emits no `session/usage` event, which would
  record a row and be measured for the output rate again; the session is
  saved and announced (`session/changed`).  A RECORD with neither
  number changes nothing.
- `session/set-todos ID TODOS`, `session/set-plan ID TEXT`.
- `session/set-ext ID KEY VALUE &optional HINT` → session plist: sets the
  setting KEY of ID's `:ext`.  KEY is a keyword, or a symbol or a string
  naming one (what a client over the wire sends).  VALUE nil removes KEY;
  `:false` is stored as it is and means an explicit off; a value that
  would not survive the JSON store (see "Session") is kept in memory but
  logged.  A string HINT joins the transcript as a hint.  The change is
  saved and announced like any other (`session/changed`), and the event
  `session/ext-changed ID KEY VALUE` says which setting changed, KEY
  being the keyword and VALUE nil once it was removed.
- `session/messages ID` → provider messages (content blocks) built
  from the path, tool calls paired with results.  A steering message
  marked `:delivered-after NODE-ID` stands after that node (and the
  tool results right after it), where the model got it.  Every tool_use
  is answered in the message right after it, whatever the path holds.
  A call whose result is not there gets a stand-in error result
  (`harness-session-missing-result-output`), in a user message of its
  own when none follows.  A tool_result that answers no call of the
  message before it becomes text.  That covers a call cancelled
  mid-turn, a result that came after its turn ended, and a head moved
  back between a call and its result.  The transcript itself is not
  changed, and a message that needs no change comes out as it is.  The
  images a tool returned for the model (the result node's `:images`)
  follow in the tool_result block's `:images`, image blocks that name
  their files and hold no bytes, on the block of a call that returned
  any and did not fail; the block's `:content` stays a string.
- `session/transcript-text ID` → searchable plain text.
- `session/write-transcript ID &optional OPTS` → `(:file :lines)`:
  writes `session/transcript-text` to a new Markdown file named after
  the session and the time, in OPTS `:directory` relative to the
  session's directory (`harness-session-transcript-directory`,
  `.harness/transcripts/`, by default), under a heading (`:title`), the
  session's name and id, a line on why (`:about`), its working
  directory and a legend of the entries.  The session's directory is
  where its tools read without asking and a provider's prompt cache
  holds what the model reads, unlike the state directory; a
  `.gitignore` of `*` there keeps git out.  Signals when the directory
  does not exist.  A handoff (`.harness/handoff/`) and a compaction
  into a transcript write theirs with it.
- `session/redact-text`, `session/reset-provider`,
  `session/reset-drops-cache-p` and `session/family-ids` are this
  module's part of taking a secret out of the stores, and the event
  `session/redacted ID RECORD` says it happened; see redact for all
  five.
- Event `session/changed ID SESSION` fires after any of the above (for UIs
  that just want to redraw).

### provider

```elisp
(harness-define-provider 'ID
  :label "Claude Code" :doc "…"
  :models FN            ; (&optional REFRESH) → promise of MODEL plists
  :complete FN          ; (REQUEST) → HANDLE plist (:cancel FN)
  :fork FN              ; (MODEL PROVIDER-STATE &optional CHECKPOINT) → promise of new state [optional]
  :quota FN             ; (&optional REFRESH) → promise of QUOTA (below)     [optional]
  :warm FN              ; (REQUEST) → BOOL: get ready for a request like it  [optional]
  :close FN             ; (SESSION-ID) → BOOL: free what it keeps for one   [optional]
  :resolve FN           ; (NAME &optional MODELS) → MODEL plist or nil: a name
                        ; its listing lacks (an alias, a variant)          [optional]
  :embed FN             ; (NAME TEXTS OPTS) → promise of (:vectors :usage) [optional]
  :capabilities PLIST   ; static defaults, merged with per-model ones
  :tiers PLIST)         ; a model per tier, see below
```

Embeddings: `provider/embed MODEL-ID TEXTS &optional OPTS` → promise of
`(:vectors VECTORS :usage (:input N))`, one vector of floats per string
of TEXTS, in their order.  OPTS `:dimensions` asks for shorter vectors.
It rejects a model the policy refuses (`harness-allowed-models`), one
of no provider, and one whose provider has no `:embed`.  The model
need not be in the provider's catalogue, which lists chat models: an
embedding model is named only by settings, such as
`harness-session-search-embedding-model`.  `provider/embeds-p MODEL-ID`
says whether its provider embeds.  The OpenAI-compatible endpoints embed
(`POST /embeddings`; in corporate mode only an endpoint on this machine
does); the demo provider embeds offline, words of a few related groups
near each other, for the tests and the dev daemon.

MODEL = `(:id "ID:NAME" :provider ID :name "NAME" :label "…"
:context-window N :context-window-estimated BOOL :context-window-basis "…"
:max-output N :input-modalities ("text" "image")
:thinking-levels (…) :pricing (:input F :output F :cache-read F :cache-write F)
:pricing-fn SYMBOL :resolves-to "NAME" :capabilities (…))`.  Pricing is
USD per million tokens.  `:context-window-estimated` marks a window
nobody gave for this model, and `:context-window-basis` says what it
was drawn from (see below); `:resolves-to` is the model an alias stands
for.  A model whose rates change with the clock carries `:pricing-fn`,
a symbol called as `(MODEL USAGE AT)` that returns the pricing plist in
effect at AT; `usage/price` uses its answer instead of `:pricing`.  This
is how the DeepSeek provider follows its peak and off-peak tiers, and it
keeps the catalogue plain data that crosses the wire unchanged.

Model tiers: `:tiers` names a model for each of the four tiers of
`harness-model-tiers`, weakest first, so the harness can pick a model on
its own without the user naming one:

| Tier | For | Claude | DeepSeek |
|---|---|---|---|
| `:simple` | small, well-specified work and the harness's own calls (auto-mode judge, naming, summaries, a plan's simple steps) | Haiku | Flash at `low` |
| `:medium` | everyday work: a plan's medium steps | Sonnet | Flash at `high` |
| `:hard` | the strongest model the harness picks on its own: what a supervisor plans on, and a step `retry_step` escalates | Opus | Flash at `max` |
| `:frontier` | the very top model, which the harness never picks on its own: only the user does | Fable | nil (none) |

A tier's value is a model name, id or regexp of the catalogue; a plist
`(:model MATCHER :thinking LEVEL)`, the model run at that thinking level
(how DeepSeek makes three tiers of one model); or nil, which says the
provider has no model for the tier (`harness-provider-tiers-type` is
the customize type).  The names of old, `:cheap` and `:balanced`, read
as `:simple` and `:medium`, and a plist saved in them reads its
`:frontier` as `:hard`, the strongest model the harness picked then
(`harness-provider-normalize-tiers`).

`provider/tier-model MODEL-ID &optional TIER` returns the `:simple` one
by default.  A tier the provider does not name, and a provider that
declares none, falls back to its own catalogue sorted by price (the
four tiers spread over the priced models, `:simple` the cheapest and
`:frontier` the dearest); a tier named as nil has no model and no price
picks one.  It returns nil when the provider is unknown, lists nothing
or has no model for the tier (the caller then uses what it has);
`provider/tier-model-info` returns `(MODEL . REASON)`, REASON
`unknown`, `unlisted` or `none` saying why not, and
`provider/tier-model-async` waits for a catalogue that answers late.
MODEL-ID may also be a provider id alone.  This is what ties the judge
to the session's provider.  Claude, DeepSeek, Bedrock and Copilot name
their tiers; the dynamic OpenAI-compatible catalogues fall back to
price unless an endpoint names `:tiers`.  `provider/tier-thinking
MODEL-ID &optional TIER` returns the level the tier names, nil for a
tier that names none (Claude's), without reading the catalogue; and
`provider/fit-thinking MODEL-ID LEVEL` brings a level within the
`:thinking-levels` of the model (`max` is `high` on a model whose
strongest is `high`).

The other way round, `provider/model-tier MODEL-ID` says which tier a
model is in its provider (`simple`, `medium`, `hard` or `frontier`, a
symbol without a colon): the one `:tiers` names it for (`:medium`
first, then `:hard`, `:frontier` and `:simple`, when several do, as
DeepSeek's three name one model), else its place in the catalogue by
price (the cheapest sixth simple, the dearest sixth frontier, the
nearest tier the provider has a model for), else `medium`.  So Claude's
Fable 5.1 is `frontier` and Opus 5.5 `hard`.  The fallback module maps a
model to "its model of similar ability" at another provider through the
two, stepping to the nearest tier the other provider has (below first):
a Fable session falls back to DeepSeek's hard tier.

The catalogue is cached per provider.  Defining a provider again, as
every `harness-reload` does, forgets that provider's models and no
other's.  A provider whose models are not cached is asked by the first
`provider/model` that needs one: a static catalogue answers at once and
is cached before the call returns.  A failed listing is cached as empty
(or keeps the models listed before), so lookups do not ask again before
a refresh (`provider/models t`), which a models function that takes an
argument is told of, so it asks its source rather than its cache.
`provider/models-updated` follows every listing that is cached.  A
provider that learns something its listing should show (a new list
from its source, the window a model really ran with) calls
`harness-provider-relist ID` to have it listed and announced again.

The model lists are not hard-coded.  Each provider lists what its
source lists, with the windows the source gives: the Claude CLI's
`initialize` answer and results, the Anthropic, OpenAI-compatible,
DeepSeek and Copilot model listings, Bedrock's (sections below).  What
a provider ships is a seed for before its source answered, and for
prices.  So a new model works without a code change.

Every MODEL has a context window, and an unknown slug never silently
gets a small one.  A model its provider lists without a window, one
its provider flags as its own guess (Bedrock's family defaults), and a
name no listing holds (an alias, a model a slower provider has not
listed yet, a model of a provider that is gone) get an estimate,
flagged `:context-window-estimated t`, drawn in this order from:
1. the same model where a provider sizes it, its own provider first:
   `harness-provider-model-key` drops vendor and region prefixes, dates
   and Bedrock versions, so `us.anthropic.claude-opus-4-5-20251101-v1:0`,
   `anthropic/claude-opus-4.5` and `claude-opus-4-5` are one model;
2. the model of its own provider that shares the most leading name
   words with it, two at least (`claude-opus-5-6` takes after
   `claude-opus-5-5`, not after `claude-haiku-4-5`);
3. the window most of its provider's models have;
4. `harness-provider-fallback-context-window` (200000).
A provider's own guess gives way to the first two only.  Estimates are
drawn from windows providers gave, never from another estimate, and
made again whenever a listing changes.  A name no listing holds goes to
its provider's `:resolve` first (Claude Code's aliases, Copilot's
`default`, a Bedrock profile ARN), whose answer is estimated only where
it gives no window; the log says once per model when a listed
provider's model got an estimate.  The model picker shows an estimated
window as `~200k`.

Capabilities: `:hosted-loop` (provider runs the tool loop and keeps the
history; the agent only sends new user content, so switching to it
from another provider starts a conversation without the history unless
it is handed over: see "handoff"), `:fork`, `:resume`,
`:vision`, `:audio-in`, `:thinking`, `:cache-status`, `:quota`,
`:compaction hosted`, `:cost-reported` (usage events carry `:cost`),
`:billing` (usage events say who paid: `:billing`, `:plan`,
`:list-cost`), `:pricing dynamic` (pricing comes from the model
catalogue), `:builtin-tools` (a list of the harness tools the provider
has a tool of its own for, which it can run in their place: Claude Code
and Copilot list `"web_search"`; see `tools/builtin`), `:cache-ttl N`
(the seconds the provider keeps a prompt cache after its last use,
when it is not `harness-cache-ttl`: DeepSeek declares 10800),
`:cache-refresh` (a hosted loop's: a message sent to its process with
`:cache-refresh t` in the request only keeps the cache of the
conversation alive, and the provider refuses it when it could not run in
the process that holds the conversation as it is -- Claude Code declares
it; see "cache-warm").

Prompt cache lifetime: `provider/cache-ttl MODEL-ID &optional
REPORTED` (`harness-provider-cache-ttl`) says how many seconds MODEL-ID's
provider keeps a prompt cache after a request used it.  The first of
these that gives a positive number wins: REPORTED, the lifetime the
provider reported for the request (a usage event's `:cache-ttl`; Claude
Code tells the one-hour cache from the five-minute one); the first
entry of `harness-cache-ttl-overrides`, `(REGEXP . SECONDS)`, whose
regexp matches the model id; the model's or its provider's `:cache-ttl`
capability; `harness-cache-ttl` (300).  The session derives when its
cache lapses from it (see "Session").

REQUEST = `(:model "ID:NAME" :session SESSION :system "…" :messages (MSG…)
:tools (TOOL-SPEC…) :thinking LEVEL :max-tokens N :provider-state PLIST
:on-event FN)`.  MSG = `(:role user|assistant|tool :content (BLOCK…))`.
TOOL-SPEC = `(:name :description :schema JSON-SCHEMA-PLIST)`.  For hosted
loops only the trailing user message is sent: the user messages after
the last assistant message, less tool results.  A turn's
`:provider-state` is the session's state when the request's model can
continue it (`session/provider-state`), else nil.  A REQUEST may also carry
`:builtin-tools`, a list of harness tool names (from `tools/builtin`):
the provider turns on its own tools in their place for this request,
and `:tools` lacks them.  `:no-thinking t` asks for no extended
thinking, and wins over `:thinking` when both are sent.  Claude Code,
which takes no `:max-tokens`, then runs the CLI with
`MAX_THINKING_TOKENS=0`; a DeepSeek endpoint sends `reasoning_effort`
"none", its off switch; an endpoint with no off switch sends nothing,
so a model whose thinking is on by default may still think (see the
auto-mode judge's retry below, which covers that).

A REQUEST with `:ephemeral t` is a one-off question, such as the
auto-mode judge's.  The provider answers it from the request alone, as
if nothing came before it and nothing comes after it: it brings no
earlier conversation, keeps none, and loads no context of its own
(project instructions, memory).  Providers that send the whole request
every time (the HTTP APIs) already work that way.  Claude Code starts
a throwaway CLI process for it, and Copilot a throwaway session (see
below).

A REQUEST with `:job`, a few words saying what a call the harness makes
on its own is for ("Permission judge", "Auto-name", "Recap"), is
recorded as an internal session (`session/internal-start`, see
"session"): `:job-parent` is the session the call is made for, which
the new session is listed under, and `:job-project` the project it
belongs to when no parent says (the Insights summary, the pet and the
task board's search have none).  `provider/complete` starts the session
before the provider is asked, with the model, the directory and host of
`:session` and the text of the request's last user message as the
prompt, and strips the three keys, so no provider sees them.  The
caller's `:on-event` still gets every event as it would without them;
after each, the session records it: `text` is gathered for the reply,
`usage` is added to the session's totals (`session/usage-add`, so the
call's cost is counted once, which is why the callers that used to
record their own usage -- the Insights summary, the pet, the task
board's search -- skip it while the method exists; if starting the
session fails, which is logged, their usage goes unrecorded), and `done`,
whatever its stop reason, finishes the session with the reply
(`session/internal-finish`).  A request the allow list refuses or that
fails in setup finishes it too.  A failure of the recording is logged
and goes no further; a request without `:job`, or a harness without the
method, is not recorded.  Callers: the permission judge, the Elisp
judge, the session judge, auto-naming (`naming/title` too, with no
parent), recaps, the Insights summary, the pet and the task board's
search.

Events delivered to `:on-event` (one plist each, in order):

```elisp
(:type start)
(:type text :delta "…")
(:type thinking :delta "…")
(:type tool-call :id "…" :name "…" :input PLIST :respond FN-OR-NIL :checkpoint PLIST)
   ;; :respond present ⇒ hosted loop; call it with a tool result
   ;; (:content "…" :is-error BOOL) and the provider continues the turn.
(:type tool-result :id "…" :content "…" :is-error BOOL)  ; hosted loops echo results
(:type checkpoint :checkpoint PLIST :call-id "…")  ; hosted loops: where the conversation stands
(:type usage :input N :output N :cache-read N :cache-write N :cost F-OR-NIL :context N
       :last-output N                   ; hosted loops: what the turn's last call wrote
       :list-cost F-OR-NIL :billing api|subscription|extra-usage|nil :plan ID
       :cache-at FLOAT :cache-ttl N)    ; see Usage record; the last two optional
(:type call-usage :output N :context N) ; hosted loops: one model call's output, counted by the turn's usage;
                                        ; :context, optional, the size of the call's prompt
(:type provider-state :state PLIST)     ; persist on the session
(:type activity :phase PHASE :tool NAME :chars N)  ; what the model is busy with, see below
(:type quota :windows (…))
(:type hint :text "…")                  ; provider-side notices (compaction, retries)
(:type done :stop-reason end-turn|tool-use|max-tokens|cancelled|error :error "…"
       :error-kind quota|billing|rate-limit|auth|… :resets FLOAT)  ; the last two optional
```

A `done` with `:stop-reason error` may say what kind of failure it was,
when the provider knows: `:error-kind` `quota` (a plan's usage limit is
used up: Claude Max's 5-hour or weekly window, Copilot's monthly
allowance), `billing` (out of money: a prepaid balance or credit spent,
an account on hold), `rate-limit` (a short-term limit; the provider
works again in a moment), or another symbol for anything else (`auth`).
`:resets` is when a quota comes back, as a float time, when the
provider was told.  The Claude provider reads the CLI's assistant
`error` field (`rate_limit` while a usage window is `rejected`,
`billing_error`, `account_on_hold`) and the `resetsAt` of the
`rate_limit_event` that rejected the call; the OpenAI-compatible one
HTTP 402 (DeepSeek's "Insufficient Balance") and a 429 whose code is
`insufficient_quota`; Copilot a `session.error` of type `quota` or
status 402.  The fallback module (below) classifies failures that come
without a kind from their text.

A provider that runs one of its own tools in place of a harness tool
(one the request's `:builtin-tools` names) reports its calls with three
events, all naming the harness tool and the provider's call id:
- `tool-call` with `:builtin t` and no `:respond`, once per call, as
  soon as the provider knows the call's input.  The agent records the
  call node (meta `:builtin t`), shows it running, and runs nothing.
- `(:type tool-permission :id ID :name NAME :input PLIST :respond FN)`
  when the provider wants to know whether the call may run.  The agent
  asks `tools/authorize`, so the harness's permission chain decides it
  as a call of NAME, and calls FN with the DECISION: `(:behavior allow
  ...)` or `(:behavior deny :message TEXT ...)`, TEXT being what the
  model is to be told.
- `tool-result`, which the agent records as the call's result (meta
  `:builtin t`, plus `:denied t` after a refusal).  Results of other
  calls, which hosted loops echo too, are not recorded twice.

A built-in call still open when the provider's request ends (`done`, or
the turn cancelled) gets an error result saying it got none, so every
call in the transcript has a result.

`activity` says what the model is busy with when its output alone would
not: PHASE `thinking` (a thinking block began, whether or not its text
streams), `writing` (a text block began), `tool-input` (the model writes
the input of a call to `:tool`, `:chars` characters so far, reported at
most every quarter second), `compacting`, or `waiting` (for the model
again).  The Claude provider sends all of them: the CLI streams a
thinking block without its text and a tool call's input as JSON
fragments, so without them a turn shows nothing for as long as the model
thinks or writes a large input.  The OpenAI and Bedrock providers send
`tool-input`, and the live token count counts its characters (see
"usage").
Text deltas that are only whitespace are still text (a `"\n\n"` delta
separates paragraphs); the agent keeps them from opening a message.

`call-usage` reports the output tokens of one model call of a hosted
loop's turn as soon as the call ends. A hosted loop sends a single
`usage` event, for the whole turn, at its end, and that event is the one
that counts: `call-usage` is not recorded anywhere. The agent passes it
on as `agent/call-usage`, so the usage module can measure the output
rate and keep the live token count during a long turn.  `:context`, when
the provider knows it, is the size of the prompt the call was sent, the
conversation so far.  The turn's `usage` says with `:last-output` what
its last call wrote, so the session's context in use stays as the live
count left it.
- Claude Code sends a call's prompt as its `message_start` arrives
  (`:output 0`), then the output that each `message_delta` adds to its
  message.
- Copilot sends each main-conversation `assistant.usage`, with the
  call's prompt. Sub-agent calls do not count, because their deltas do
  not stream into the conversation either.
- Native loops send none: their `usage` event is already per call.

Forking: `provider/fork` returns a new provider state that may be marked
pending (for the CLI: `(:cli-session-id PARENT :fork-pending t)`); the
first completion consumes it and emits a `provider-state` event that the
agent persists, replacing the pending one.  When it returns nil or
fails, the fork starts without provider state: copied as is, the
parent's would make the fork resume the parent's own CLI session.

Provider state: a state belongs to the provider that wrote it and says
so as `:provider` (a string).  The agent tags each `provider-state`
event with the provider of the model the step went to -- not the
session's model, which a switch during the step changes -- and
`provider/fork` tags what it returns (`harness-tag-provider-state`,
`harness-provider-state-owner`).  Each step sends only a state its
model can continue (`session/provider-state`); a state of another
provider is dropped from the session at that step, since that
provider's turns are ones the state's conversation never saw.  So a
session switched away and straight back resumes its conversation,
while one that ran a step elsewhere starts a new one there, which
`handoff/check` calls lossy.  Naming a whole conversation, compaction
and forks work on a fork of a state their model can continue, never on
another provider's.

Checkpoints: a hosted loop says where its conversation stands as
content lands in it, so that a fork or a checkout at a node can cut the
conversation there later.  A `checkpoint` event without `:call-id`
marks the text or thinking node the turn wrote last (unless a tool call
came after it), one with `:call-id` that call's result, and a
`tool-call` brings its own `:checkpoint`; the agent stores each as the
node's `:checkpoint`.  `provider/fork MODEL STATE CHECKPOINT` returns a
state holding the conversation as it was at CHECKPOINT and nothing
after it (Claude Code: `(:cli-session-id ID :resume-at UUID
:fork-pending t)`, a fork of that CLI session cut with
`--resume-session-at`), or nil when the provider cannot cut there: a
fork function of two arguments, another provider's checkpoint, or
Copilot, whose events carry no checkpoints yet.

Replay: a hosted loop that starts a new conversation for a request whose
`:messages` have messages before the new one (a cut before any
checkpoint, a conversation another provider held, one the CLI could not
resume) sends them first, as text, with the new message
(`harness-provider-split-history`, `harness-provider-history-text`: tool
inputs and results cut at `harness-provider-history-block-limit`, the
oldest messages but the first dropped past
`harness-provider-history-limit`, thinking left out).

Methods: `provider/list`, `provider/models &optional REFRESH` (cached union
across providers), `provider/cached-models PROVIDER-ID` (one provider's
cached models, at once: a provider not listed yet is asked, and gives
nil until it answers; no other provider holds it up),
`provider/model MODEL-ID` → MODEL, `provider/capabilities MODEL-ID`,
`provider/cache-ttl MODEL-ID &optional REPORTED` → seconds (above),
`provider/complete REQUEST` → HANDLE, `provider/fork MODEL-ID STATE &optional
CHECKPOINT` → promise, `provider/quota PROVIDER-ID &optional REFRESH`,
`provider/warm REQUEST` (ask the provider to prepare what a request like
REQUEST, which has no messages, will need -- the Claude CLI spawns its
process now, so the answer comes sooner; a failure is only logged) and
`provider/close MODEL-ID SESSION-ID` (free what the provider keeps for the
session id of a request made outside any session, such as a task
board's search; the CLI kills its process).  The model used when nothing
more specific is configured is `harness-model`.

`harness-allowed-models` keeps the harness to some models: glob
patterns of model ids (`"claude:*"`; one without a colon names a
provider), nil for any; an administrator's policy may set it
([policy.md](policy.md)).  `provider/complete` refuses a request for
another model before any provider sees it, with a `done` event of
`:stop-reason error` that says why (`harness-provider-model-refusal`),
so it holds for every request, the judge's, naming's and compaction's
included.  `provider/warm` does not warm one, `provider/models` lists
only the models allowed, and `provider/tier-model` chooses among them.

Billing and quota: `provider/quota` (PROVIDER-ID a symbol or its name;
REFRESH asks for fresh data first) returns a promise of QUOTA, nil when
the provider reports none:

```elisp
(:billing api|subscription|nil      ; who pays for the account's calls
 :plan "max" :plan-label "Claude Max" :account (:email "..." :organization "...")
 :auth "claude.ai"|"ANTHROPIC_API_KEY"|"bedrock"|...  :api-provider "firstParty"|...
 :available BOOL                    ; the plan reports quota windows
 :windows ((:name "5h" :label "Current session (5 hours)" :used FRACTION
            :resets FLOAT :severity "normal" :active BOOL :model "Fable") ...)
 :extra (:enabled BOOL :used F :limit F :currency "USD" :disabled-reason "...")
 :limit-status "allowed"|"allowed_warning"|"rejected"
 :using-extra BOOL                  ; calls draw on extra usage, billed at API prices
 :updated FLOAT)                    ; when the windows were last reported
```

Event `provider/quota-updated PROVIDER-ID QUOTA` fires whenever a
provider learns something new; the UI caches QUOTA from it, and the
usage module counts `:extra :used` in month budgets over everything
(see usage).

The Claude provider learns the billing from the `account` of each CLI
process's initialize answer:
- an API key, an API key helper, a bearer token or a cloud provider
  bills per token;
- a claude.ai login (Pro, Max, Team, Enterprise) is a subscription.

Quota comes from the CLI's `get_usage` control request (the data behind
`/usage`, no model call) and from `rate_limit_event` messages.  It is
asked for again after a turn once `harness-provider-claude--quota-ttl`
(60 s) has passed.  With no CLI process running, a short-lived probe
process answers instead, sending no message.

The Claude provider's models are what the CLI says they are.  Every
`initialize` answer (each new process's, the quota probe's, and a
probe's started when a refresh asks) lists what its /model picker
offers: aliases such as `opus` and `sonnet[1m]`, their labels and effort
levels and, from Claude Code 2.1.197 on, the model each resolves to.
Every result's `modelUsage` gives the context window the CLI ran each
model with, and the name a process was started with takes the window
of the model it ran.  With an Anthropic API key
(`harness-provider-claude-api-key`, else ANTHROPIC_API_KEY or
auth-source), `GET /v1/models` adds every model the API serves, with
its window, output limit and effort levels.  What was learned is kept
in `claude-models.json` in the state directory;
`harness-provider-claude-models` only seeds the catalogue and gives
prices.  An alias or a name nothing lists is resolved
(`harness-provider-claude--resolve`): a learned window, a `[1m]`
variant's million tokens, the window of the model it resolves to, else
the window of its family's newest listed model, flagged as an estimate.

Each result's `total_cost_usd` is a running total for the process,
seeded on `--resume` with the session's restored spend.  A turn
therefore costs the difference to the previous total, starting from the
`session.total_cost_usd` the spawn-time usage report gives.

The Claude provider never needs the CLI to bypass its permission
checks.  The CLI gets no built-in tools (`--tools ""`), only the
harness's MCP tools, whose calls the harness's permission system
decides.  `harness-provider-claude-permission-args` only has to let
them through.  It defaults to `--permission-mode default --allowedTools
mcp__harness__*`: a fixed mode, so no settings file starts the CLI in
plan or auto mode, plus an allow rule.  Where managed settings make the
CLI ignore such rules, `--permission-prompt-tool stdio` sends its
permission prompts to the harness instead, as `can_use_tool` control
requests; the harness allows its own tools and refuses any other.  A
tool call the CLI refuses on its own (`system/permission_denied`)
becomes a `hint` that names the setting.

*Why not `bypassPermissions`.*  The first version started the CLI with
`--permission-mode bypassPermissions`, the simplest way to let every
tool through.  An organisation's managed settings can forbid it
(`permissions.disableBypassPermissionsMode`); Claude Code 2.1.308 then
runs the session in `default` mode instead, where a headless CLI with
no one to ask denies every call, and the harness was useless on such a
machine until the arguments were changed (commit 2539e94, "let the CLI
run harness tools by rule, not bypassPermissions", which also added
`harness-provider-claude-permission-args`, the `can_use_tool` answers
and the denial hint; 53daeda added WebSearch as a stand-in for
web_search on the same footing).  Every permission arrangement of this
provider has to hold up under managed settings, which outrank anything
the command line says: a managed deny rule always wins (no flag
overrides it), `allowManagedPermissionRulesOnly` makes the CLI ignore
the command line's allow *and* ask rules (what the CLI then prompts for
still reaches the harness through the prompt tool), and
`disableBypassPermissionsMode` turns the bypass modes into `default`.
So the provider only ever uses `--permission-mode default`,
`--allowedTools`, ask rules and the prompt tool, and a test asserts
that none of the command lines it builds holds `bypassPermissions` or
`--dangerously-skip-permissions`.

A session whose context window is below its model's (a task's is capped
by `harness-tasks-context-limit') is spawned with
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` set to that percentage, so the CLI
auto-compacts at the shorter budget the harness gave the session rather
than at its own default.  The percentage is part of the settings a
process was started with, so changing the cap restarts the CLI with
`--resume`, like the model and system prompt.

The CLI loads the CLAUDE.md files as `claude` does, but not Claude
Code's auto memory: every process it starts gets
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` unless
`harness-provider-claude-auto-memory` is on.  The memory's index,
MEMORY.md, lists notes kept under `~/.claude/projects/PROJECT/memory/`,
which Claude Code reads and writes with its own file tools, following
instructions in its own system prompt.  A harness session has neither,
so the model opened the notes with the harness's file tools, outside
the allowed directories, and every session asked the user for that
directory (or, unattended, was refused it).  Whether a process loads
the memory is part of the settings it was started with, so changing the
option restarts the CLI with `--resume`.

The first exception is WebSearch, which stands in for web_search
(`harness-provider-claude-builtin-tools`; capability `:builtin-tools`).
A request whose `:builtin-tools` names web_search starts the CLI with
`--tools WebSearch`, plus `--permission-prompt-tool stdio` unless the
permission arguments already send the prompts somewhere or bypass the
checks, so the CLI asks before every search.  The model's `tool_use`
becomes a `tool-call` marked `:builtin` (named web_search), the
`can_use_tool` question a `tool-permission` that the harness's
permission chain answers (allow, or deny with the message for the
model), and the echoed `tool_result` a `tool-result`.  The process
records which tools it was started with, so a request that turns
WebSearch on or off restarts it with `--resume`.

The CLI asks for the harness's tools (MCP `tools/list`) once, in a
handshake that follows the harness's `initialize`, and keeps the list
for the life of the process.  That handshake can come while no turn is
in flight: a request whose trailing messages are only tool results
spawns the process and ends at once ("No user message to send"), as
the first step after a mid-turn switch to Claude Code did.  So the
process record keeps the tool set of its last request after the turn
(`tools` slot) and `tools/list` answers from it, never with an empty
list for want of a running turn.

A tool result's pictures (`:images` of the `:respond` argument, see
agent) go to the CLI inside the MCP result: its `content` is the text as
one `{type:"text"}` block, then a `{type:"image", data, mimeType}` block
for each picture (`harness-provider-claude--image-blocks`), which the CLI
documents as an image of the tool result for the model.  A picture with
no data or no media type is left out, so the text always goes.  A result
with none is the single text block it always was.  The CLI turns a tool
result away past 25,000 tokens (`MAX_MCP_OUTPUT_TOKENS`) and counts an
image's base64 in them, about four characters a token, which would
refuse any picture over 75 KB, so every process the provider starts has
the limit raised to 2 million
(`harness-provider-claude--mcp-output-tokens`); the harness's tools keep
their text short themselves.  A result that cannot be encoded as JSON
is answered with an error that says so, text alone and without its
pictures.  None of this was run against the real CLI, which the tests
stand a fake in for (test/fixtures).

Every `assistant` message and tool-result echo of the CLI carries the
uuid of its entry in the CLI session's chain; messages of a sub-agent's
chain (`parent_tool_use_id`) do not count.  The provider reports them
as checkpoints `(:cli-session-id ID :uuid UUID)`: a message with a
`tool_use` on that call's `tool-call` event (the call is served later),
any other at once, and an echo once per result it holds.  A fork at a
checkpoint is `(:cli-session-id ID :resume-at UUID :fork-pending t)`,
which spawns `--resume ID --fork-session --resume-session-at UUID`: the
CLI keeps the chain up to and including that entry (print mode only,
which the provider uses).  A running process is reused only when it was
started with the request's settings and holds the CLI session the
request's state names -- a session whose state was dropped, because it
went on with another provider, starts a new CLI session rather than
carry on a stale one; a `:fork-pending` state always gets a new one.
`session/provider-state-changed` to a state naming another CLI session,
or none, closes the session's idle process.

A process told to resume or fork that exits before it announces its
session (`system/init`) could not open that conversation: the CLI
session is gone, the uuid lies before a compaction of the CLI's (a
resume loads only the chain since the last one), or the CLI is too old
for `--resume-session-at`.  The turn then goes on in a new CLI session,
which gets the transcript and the turn's message, and a hint says so; a
session never gets stuck on a conversation the CLI cannot resume.  A
new CLI session opened for a transcript that has messages before the
new one gets them the same way.

A request whose provider state is not the one its session has recorded
(naming the whole conversation sends a fork of it) runs in a CLI
process of its own, closed when it is done.  It never restarts the
session's process with its own settings or writes into the session's
CLI session.

A one-off request (`:ephemeral t', the permission judge's, or naming a
session from its first message) gets a CLI
process of its own whatever its state, under a key of its own
(SESSION-ID~N), never resumed and stopped once it is done (its input is
closed, and it is killed if it still runs a few seconds later).  It
runs with `harness-provider-claude--ephemeral-environment'
(`CLAUDE_CODE_DISABLE_CLAUDE_MDS=1',
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1',
`CLAUDE_CODE_SKIP_PROMPT_HISTORY=1'; a CLI that does not know one
ignores it), so it loads no CLAUDE.md and no auto memory and saves no
transcript, and a local session's runs in a private empty directory,
`claude-one-off/' in the state directory, rather than the project's, so
no project settings or hooks apply either.  This keeps the permission
judge's verdicts on the call alone.  When the judge kept one CLI
conversation per session, started in the project, each verdict saw the
earlier ones (whether the work had been handed in, say) and the
project's CLAUDE.md, and judged by them.

The CLI keeps each conversation in `PROJECTS/SLUG/ID.jsonl`, and what
belongs to it (a long tool output, a sub-agent's log) in
`PROJECTS/SLUG/ID/`: ID is the CLI session (`:cli-session-id` of the
provider state), SLUG names the directory the CLI ran in, and PROJECTS is
`harness-provider-claude-projects-directory`, by default the `projects`
directory of `$CLAUDE_CONFIG_DIR`, else of `~/.claude`.  `--resume`
replays those files, so a secret that got into a conversation stays in
them after the harness's own copies are clean.
`provider/claude-redact-logs` takes secrets out of them (see redact).

The Bedrock provider (`provider-bedrock`) is a native loop over the
Converse API: one ConverseStream request per call, its binary event
stream decoded into `text`, `thinking`, `usage` and `tool-call` events.
Each entry of `harness-bedrock-endpoints` is a provider (default
`bedrock`); model ids are `ID:MODEL-ID`.  Its catalogue comes from
ListFoundationModels and ListInferenceProfiles, cached an hour per
endpoint; a refresh lists again, and a listing that fails keeps the
models listed before.  Context windows and prices, which Bedrock does
not report, come from `harness-bedrock--model-defaults`; a family's
catch-all window there is flagged as a guess, which the same model's
window at another provider replaces, or else that of the endpoint's
closest model by name that the defaults size.  A model no default knows gets
the endpoint's `:default-context`, else an estimate, and a name the
listing lacks (an application inference profile ARN) is described from
the defaults by its `:resolve`.  Usage events carry tokens and
`:billing api` but no cost, so `session/usage-add` prices them from the
catalogue.  Claude and Nova requests carry prompt cache points; Claude
reasoning returned with tool calls is kept and sent back with them while
the tool loop lasts.  An adaptive model is asked for the effort the
thinking level names, fitted to the levels it offers by the shared rule
(`harness-thinking-level-fit`); a model that thinks within a budget gets
the budget of the level (`harness-bedrock--thinking-budgets`).  A
request is repeated, up to three times, when the connection was lost
before any of the answer arrived (`:retry t`, the HTTP layer's, see
retry: the request goes again as it was signed), and
a throttled or failed response (429, 5xx, a throttling exception) while
nothing has been streamed yet, with a hint for each wait
(`harness-bedrock--maybe-retry`).  `harness-http-request` takes
`:binary t` for such framings: the response then reaches `:on-chunk` as
unibyte strings.

The pictures a tool returned (the `:images` of a `tool_result` block, each
with `:data` or only a `:path`, read when the request is built) ride in
the block's `toolResult`, whose `content` is `[{text}, {image: {format,
source: {bytes}}}…]`, for the models Converse documents an image there
for: Claude and Nova (`harness-bedrock--tool-images-p`, by the model's
id or its foundation model's).  For any other model that reads images
they follow the tool results of their message instead, each after a text
block `[Image returned by tool call ID]`
(`harness-bedrock--lift-tool-images`), because Converse rejects an image
in a tool result there and the history would keep the request failing.
A request without tools flattens a result to text and the pictures
follow its text.  Converse takes at most 20 images in a message, each
up to 3.75 MB and 8,000 pixels on a side; the provider does not enforce
that: read_file keeps the image it shows to its own limits
(`harness-tools-fs-image-max-bytes` and `-max-side`) and the agent sends
the newest `harness-agent-history-images` only.

An endpoint can point at a gateway in front of Bedrock instead.  Its
`:endpoint-url` holds the prefix that Bedrock's paths go under, and a
query that every request keeps (`harness-bedrock--url`).  Listing
follows a runtime URL whose host is not AWS's
(`harness-bedrock--control-url`), so a gateway's keys and headers never
go to AWS.  Requests are authenticated in one of three ways:

- An API key in the header the endpoint names.  It comes from a
  variable, auth-source, or `:bearer-token-command`, whose output is
  kept until the key expires.  The command runs again once when the
  gateway refuses the key, for a chat request or a listing.
- SigV4 for the gateway's own URL.
- SigV4 for Bedrock's own URL, with `:sign-for-aws`, for a gateway that
  passes requests on unchanged.  The AWS host is signed but not sent.

`${NAME}` in `:headers` is read from the environment and kept out of
every message.  Saving the setting re-registers the providers.  It also
forgets the cached models, quirks and kept keys of each endpoint whose
entry changed (`harness-bedrock--forget-endpoint`), so an edit shows
at once, and a listing that fails after it does not bring back the
models of the old setup.  The tests run a stub gateway from harness-bedrock-mock.el
(`:prefix` and `:checks`), and nothing else is reachable while they
run.

The OpenAI-compatible provider (`provider-openai`) makes a provider of
each entry of `harness-openai-endpoints`.  Its models are what the
server lists at /models, asked again after an hour or when a refresh
asks; a listing that fails keeps the models listed before.  The window
comes from whichever field the server names it with (`context_length`
and `top_provider.context_length` of OpenRouter and others,
`context_window` of Groq, `max_context_length` of Mistral and LM
Studio, `max_model_len` of vLLM, `max_input_tokens` of LiteLLM), else
the endpoint's `:default-context`, else the catalogue's estimate:
plain OpenAI lists ids alone.

A `{"role":"tool"}` message holds text only, so the pictures a tool
returned (the `:images` of a `tool_result` block, each with `:data` or
only a `:path`, read when the request is built) go in the user message
that follows the tool messages of their harness message
(`harness-openai--tool-image-parts`): for each, a text part `[Image
returned by tool call ID]` and the picture as an `image_url` data URL,
ahead of the message's other user parts.  Nothing goes between the
assistant message that made the calls and their tool messages, which
every API requires.  A file that cannot be read any more becomes a text
part `[Image returned by tool call ID is not available]`, since the
path stays in the transcript and a request that failed on it would fail
on every later turn.  The agent gives this provider pictures only for a
model that lists image input; a DeepSeek model lists it only when its
catalogue entry says `:vision`.

The DeepSeek provider (`provider-deepseek`, `deepseek:` models) is the
OpenAI-compatible one with `:flavor deepseek`: the streaming comes from
harness-provider-openai.el, which splits DeepSeek's cached input out of
`prompt_tokens` (its `:input` bills the cache misses, `:cache-read` the
hits), sends the reasoning efforts DeepSeek accepts, and rebuilds
`reasoning_content` on assistant messages from their recorded thinking
(empty when there is none).  DeepSeek acts on three efforts only — low,
high and max (`harness-openai--deepseek-efforts`) — and collapses the
levels in between the way its own API does (minimal is low; medium and
xhigh are high), so a model advertises that three-step ladder and the
thinking menu offers no level DeepSeek cannot tell apart.  Its /models
route reports the ladder (`effort.supported_levels'), which the
catalogue takes as the model's `:thinking-levels'.  DeepSeek's thinking
mode, on by default,
rejects a tool-using history whose assistant messages omit that field,
so the whole conversation goes back to it, not just the model's own
call.  The handling follows an official DeepSeek host, not only the
flavor: a hand-written OpenAI-compatible endpoint at `api.deepseek.com`
still gets it (even when it names `:flavor openai'), so its tool loops
do not 400, and the cache fields it reports are split so cached input is
billed at the cache-hit rate, while OpenAI and OpenRouter hosts still
drop thinking.
`harness-deepseek-*` adds registration and prices.  Its models are
what DeepSeek's /models lists (names, windows, output limits,
modalities, effort levels), asked in the background once the listing
is an hour old, so the catalogue never waits on the network;
`harness-deepseek-model-specs` adds prices and labels, and is what is
listed before /models answered or when it cannot be reached.  A model
DeepSeek adds is priced by the tier its name says (flash or pro).
The provider is created only while a key is found
(`harness-deepseek-api-key`, DEEPSEEK_API_KEY, or auth-source), so
nothing uncallable is listed; see `harness-deepseek-always-register`.
DeepSeek bills peak hours
(01:00-04:00 and 06:00-10:00 UTC, Monday to Friday, minus Chinese public
holidays) at double the off-peak rate, so the catalogue carries
`:pricing' (off-peak) and `:peak-pricing' and the model's
`:pricing-fn' picks between them; cached input, cache-miss input and
output are priced separately.  A `provider/pricing-warning` event and a
session hint say once per peak window that a call costs more.

The Copilot provider (`copilot:` models) drives `copilot --headless
--stdio`, the GitHub Copilot CLI's server mode that GitHub's Copilot
SDKs use: JSON-RPC 2.0 framed by `Content-Length` headers, SDK protocol
version 3 or newer.  Per harness session one CLI process:
- `connect` then `auth.getStatus` start it; a CLI that is not logged
  in, too old, missing or silent fails the turn with what to do.
- `session.create` / `session.resume` open a Copilot session whose only
  tools are the harness's (external tools, `availableTools` set to their
  names) and whose system prompt is the harness's (`systemMessage` mode
  replace); resuming an open session again applies changed settings.
  The request's thinking level is the session's `reasoningEffort`,
  fitted to the efforts the catalogue lists for the model by the shared
  rule (`harness-thinking-level-fit`); a model that lists none gets none.
- The exception is Copilot's own web_search, which stands in for the
  harness's (`harness-provider-copilot-builtin-tools`; capability
  `:builtin-tools`).  A request whose `:builtin-tools` names it lists
  it in `availableTools` and sends no external tool of that name.  Its
  `tool.execution_start` (or the `toolRequests` of the model's
  `assistant.message`) becomes a `tool-call` marked `:builtin`, a
  `permission.requested` about it, matched by `toolCallId` or
  `toolName`, a `tool-permission` whose decision answers
  `session.permissions.handlePendingPermissionRequest` (approve-once,
  or reject with the message as feedback), and its
  `tool.execution_complete` a `tool-result`.  Which permission kind the
  CLI uses for web_search was not checked against the real CLI.
- `session.send` runs a turn.  `assistant.message_delta` and
  `assistant.reasoning_delta` stream, `external_tool.requested` becomes a
  `tool-call` whose `:respond` answers `session.tools.handlePendingToolCall`
  (the result's text is `textResultForLlm`; its pictures, the `:images`
  of the argument, are `binaryResultsForLlm`, `[{data, mimeType, type:
  "image", description}…]` with the file's name as `description`, only
  when there are any, `harness-provider-copilot--binary-results`),
  `assistant.usage` reports each model call, `session.idle` ends the
  turn, and `session.abort` cancels it (the process is killed when it
  stays busy).  A request the CLI leaves unanswered (opening a session,
  forking one, sending) fails after `harness-provider-copilot--startup-timeout`
  (30 s) instead of hanging.
- The provider state is `(:copilot-session-id ID :model NAME)`; a fork's
  is `(:copilot-session-id PARENT :fork-pending t)`, which the first
  turn turns into `sessions.fork`.  A fork at a checkpoint is nil:
  Copilot reports none yet (`sessions.fork` takes a `toEventId` it
  could use), so a fork or a checkout at an earlier node starts a new
  Copilot session.  The first message to a session created for a
  transcript with messages carries them (see "Replay").
- The CLI keeps each session in `STATE/ID/` (`events.jsonl` and the
  files beside it) and resumes it from there: ID is `:copilot-session-id`
  and STATE is `harness-provider-copilot-state-directory`, by default
  `session-state` in `$COPILOT_HOME`, else in `~/.copilot`.
  `provider/copilot-redact-logs` takes secrets out of those files (see
  redact).
- Side requests are one-off questions: naming, compaction and the
  permission judge.  A request is one when it sets `:ephemeral` (the
  judge's, and naming a session from its first message) or
  `:max-tokens` (a turn
  of the conversation never caps its answer), when its provider state
  is not the one its session has recorded (naming the whole
  conversation brings a fork of it), or when its session record has no
  state at all (the judge's and naming's).  Any
  number of them run at once, beside the conversation's turn and beside
  each other, each in a throwaway session: a fork of the conversation
  its own state names, else of the one its session has recorded (so a
  summary for compaction sees the real conversation), else a new
  session.  They never write into the conversation, and their sessions
  are deleted afterwards (by the next process when theirs goes away
  first).  Only a new turn of the conversation takes over from the
  running one.

Copilot plans include a monthly allowance, counted in AI credits ($0.01
each, at each model's token prices) or, on the legacy billing, in
premium requests.  A turn's usage says `:billing subscription`, `:cost`
0 and as `:list-cost` the dollar value of the nano AI units the CLI
reports (none on the legacy billing: the catalogue's token prices price
it); `extra-usage` at that value once the allowance is used up and
additional usage is on.  Quota comes from `account.getQuota`
(`premium_interactions`: a window named `credits` or `premium`, plus
`:extra`) and from the snapshots in `assistant.usage`.  The catalogue
comes from `models.list` (context window, image input, reasoning
efforts, token prices as `:pricing`), or before `copilot login` from
`models.getBuiltInCatalog`, asked of a short-lived probe process when
no session process runs.  `copilot:default` resolves to
`harness-provider-copilot-default-model`, with that model's window,
levels and prices.

#### Looking like an ordinary Claude Code session (experimental)

A company that records its people's Claude Code sessions with
OpenTelemetry sees, for a harness session, a stream unlike any other:
Claude Code logs its own tools under their names (`tool_name` Bash,
Read, Edit...; with `OTEL_LOG_TOOL_DETAILS` the command, the path), and
an MCP tool as the opaque `mcp_tool`, its server and tool names shown
only with that flag.  Every call of a harness session is the second
kind, to a server of the unusual transport `sdk`, which only programs
that embed the CLI register.  That can look like a way round the
company's tool rules and logging, though the harness's own permission
chain and transcripts are doing the same job.  Two options, both off by
default, make a session look like the sessions of everyone else, and
neither asks the CLI to bypass anything.

What a collector receives, observed with Claude Code 2.1.308 sending
its OpenTelemetry logs (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, the `otlp`
logs exporter, no `OTEL_LOG_TOOL_DETAILS`) to a local receiver, for a
session whose model makes three tool calls:

| | `tool_decision` and `tool_result` | `mcp_server_connection` |
|---|---|---|
| Default (SDK server) | each call: `tool_name` `mcp_tool`, `tool_source` `mcp`, `mcp_server_scope` `dynamic` | none: the host registers an SDK server, and it is not announced |
| Native tools and the plugin | `Bash`, `Read` and `Edit`, `tool_source` `builtin`, decided by the permission prompt tool (`source` `user_temporary`); `mcp_tool` only for the plugin's own tools | `transport_type` `stdio`, `is_plugin` `true`, and a `plugin_loaded` event |

`harness-provider-claude-native-tools` has the CLI run the harness tools
it has counterparts of with its own tools: Bash for bash, Read for
read_file, Write, Edit, Glob, Grep, WebFetch and WebSearch (`t` is that
set, a list names the harness tools).  It reuses the WebSearch
machinery, which was written for any number of tools: capability
`:builtin-tools` lists everything the provider *can* run with the CLI's
tools, and the `agent/builtin-tools` filter
`harness-provider-claude--builtin-filter` picks, per session, the ones
the option names (`tools/builtin`), so `tools/list` leaves them out and
the CLI is served the rest.  What the CLI's tool is called with becomes
the input of the harness tool for the turn, the permission chain and
the transcript (`harness-provider-claude--tool-input`: Read's
`file_path` is read_file's `path`, Bash's milliseconds are seconds...),
so the permission rules, path jails, titles ("Read file: src/x.el")
and the access page all see a call of read_file.  The allowance goes
back to the CLI with the CLI's own input: a decision cannot rewrite it.

Who decides a native call (`harness-provider-claude-native-permissions`)
was checked against Claude Code 2.1.308 with a mock API and a managed
policy simulated under `/etc/claude-code/managed-settings.json`:

| Setting | Command line | Observed |
|---|---|---|
| `harness` (default) | `--permission-mode default --permission-prompt-tool stdio`, and one `--settings` holding `permissions.ask` for each native tool | Every call comes to the harness as `can_use_tool` (`decision_reason_rule_source` `flagSettings`), including the reads, globs, greps and read-only commands the CLI's default mode would run without asking |
| `cli` | the above with `--allowedTools Bash,Read,...` | Nothing is asked; the harness records the calls. Where the rule is ignored the prompt tool is still there |
| managed `disableBypassPermissionsMode` | the same | Unchanged: nothing here bypasses |
| managed `allowManagedPermissionRulesOnly` | the same | The CLI ignores the ask and allow rules; it asks what its mode and the managed rules leave, so the writes and commands reach the harness and the managed `allow` reads do not |
| managed `deny` rule | the same | The call is refused (`system/permission_denied`), the harness is not asked, and a hint says that settings outrank it |
| a `sandbox.enabled` settings file, the CLI's sandbox on | the same, plus `sandbox.autoAllowBashIfSandboxed` false | A command the CLI sandboxes is run without asking while that setting is true, which is its default; the flag setting turns it off, and the command is asked about.  A managed true still wins, and the sandbox is then the organisation's to trust |
| the user's own `--settings`, a bypass or `dontAsk` in `harness-provider-claude-permission-args` | native tools off | The CLI takes one `--settings`, and it would replace the harness's ask rules; a bypass or `dontAsk` leaves nobody to ask.  The harness keeps its tools and says why (`harness-provider-claude--prompts-lost`) |

Two things are worth knowing about the flags.  `--settings` is not
merged: a second flag replaces the first, so thinking off
(`env.MAX_THINKING_TOKENS`), the ask rules and the sandbox setting share
one JSON -- and a `--settings` among the user's own arguments would
replace it, which is why native tools then stay off.  `--allowedTools`
accumulates, so the harness's tools (`mcp__harness__*`) and the CLI's go
in separate flags.  The ask rules only ever ask more: a managed policy
can override them, and they allow nothing.  With Bash among the tools
the provider also denies `Bash(run_in_background:true)` and
`Bash(dangerouslyDisableSandbox:true)`: a background command is a task
the CLI reports in turns of its own, which the harness does not run, and
the sandbox escape is a decision the permission chain is not shown.
With the `cli` setting the prompt tool is named as well, after the allow
rules: where managed settings make the CLI ignore those rules, it asks
the harness rather than deny every call, which is how the first version
broke on a company laptop.

*What the harness gives up for these tools*, because the CLI runs them:
the sandbox (`harness-sandbox-policy` `required` keeps bash a harness
tool; otherwise Bash runs as Claude Code runs it), masking of secrets
in what a tool prints (`harness-secrets-mask` still masks the
transcript's copy, `harness-agent--builtin-output` keeps it short, but
the model has the output as the CLI printed it), and the tool slots that
hold work back under load.  A session on another host keeps the
harness's tools: they take its files by TRAMP name, which the permission
chain decides on.  The permission chain, the access page, the
corporate-mode tool list and the read-only and supervisor tool sets
still apply, as they decide which tools a session gets at all.

`harness-provider-claude-plugin` serves the tools that stay the
harness's (the `emacs_*`, session and task tools, ask_user, hand_in...)
from a Claude Code plugin rather than an SDK server.  A plugin cannot
declare an SDK server (the CLI drops one: only the host registers
those), so its server is a stdio one, and the harness is not a program
the CLI can start: the plugin's server is a few lines of bash that
connect to a loopback listener in the harness and copy bytes both ways
(`lisp/harness-claude-plugin.el`).  The plugin, `emacs-harness`, is
written into the state directory and the CLI started with
`--plugin-dir`; the listener is on 127.0.0.1 and a connection counts
only once its first line is the token made for that CLI process, which
the CLI gets, with the port, in its environment.  The CLI's own Bash
inherits that environment, so the model could read the token and
connect when the relay is not connected; what it would reach is this
session's tools, each call decided by the harness as any call is, which
the model has anyway.  The same
dispatcher (`harness-provider-claude--mcp-dispatch`) answers the SDK
channel and the relay; a relay's `tools/call` also names the call in
its `_meta` (`claudecode/toolUseId`), where the SDK channel's has to be
matched by name.  The tools are `mcp__plugin_emacs-harness_harness__*`
and the CLI's `mcp_servers` list shows the server with `source`
`plugin`, as any plugin's.

Several things about plugins made this more than writing a file:

- `--strict-mcp-config` hides plugin servers, so it cannot be used;
  MCP servers the user configured for Claude Code are then offered to
  the model too (a hint says so once; the harness refuses to run
  their tools), and `ENABLE_CLAUDEAI_MCP_SERVERS=false` keeps
  claude.ai's connectors out.
- The CLI connects a plugin's server in the background, a fraction of a
  second after it starts (`pending` in `mcp_status`), and a model
  request made before has none of its tools.  So the first message of a
  new process waits for `mcp_status` to say `connected`
  (`harness-provider-claude--await-plugin`); a CLI that cannot answer is
  trusted, and cancelling the turn ends the wait.
- `disableSideloadFlags` makes the CLI print that `--plugin-dir` is
  disabled and exit with status 1 before it starts (an SDK server given
  with `--mcp-config` is exempt).  The sentinel reads that, and a
  server that fails, is not loaded or does not come up in eight
  seconds does the same: the process goes, a new one opens the same
  conversation (`--resume`) with the SDK server, the turn's message is
  sent to it, a hint says why, and the plugin stays off for every
  session until the option is set again with `setopt` or Customize
  (`harness-provider-claude--plugin-broken`).
- The wait for the plugin's server belongs to the message that waits:
  a later message, or a cancel, drops it, and its watchdog, polling and
  answers act only while they are that message's own
  (`harness-provider-claude--drop-gate`).  A message cancelled before
  it was sent takes its process with it, because the CLI never got what
  it carried -- the transcript a new CLI session was to be given.
- The CLI gives up on a call of a stdio server that has answered
  nothing for 30 minutes (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`); an SDK
  server's calls are exempt.  A harness tool's call can wait as long as
  a person does (`ask_user`, `task_wait`), so these processes are given
  a switch that turns the timeout off.  The library itself listens on
  127.0.0.1 only while a CLI process has a bridge, and stops with the
  last one.
- The plugin cannot be had along with `--strict-mcp-config`, so the
  session loads the MCP servers of the user's own too.  Their tools are
  offered to the model; the CLI asks the harness about them, which
  refuses them -- unless the user's own Claude Code settings allow the
  tool, in which case the CLI runs it without asking.  The harness then
  only hears of the call (`harness-provider-claude--note-foreign-tool`)
  and says so once per server.
- The plugin is for a session on this machine's own conversation, not a
  remote host's (the relay would not reach this Emacs), not a one-off
  request such as the permission judge's, and not a request with none
  of the harness's tools to offer (a warming search, say).

### tools

```elisp
(harness-define-tool "read_file"
  :label "Read file"                      ; required: the name people read
  :description "…"                       ; what the model sees
  :schema '(:type "object" :properties (:path (:type "string" :description "…")) :required ("path"))
  :kind read|write|exec|net|meta          ; permission class
  :paths (lambda (input) (list …))        ; paths touched, for the jail
  :coalescable t                          ; may be folded into a summary block in the UI
  :subject (lambda (input) "x.el")        ; what a call is about, or nil
  :handler (lambda (input ctx) …))        ; → RESULT | string | promise
```

A tool has two names: NAME, the identifier the model calls it by, and
its `:label`, a short name in sentence case for people ("Read file",
"Bash", "Web search").  The label is required (`harness-define-tool`
signals without one) and every UI shows it wherever it names a tool;
the identifier stays for the model, for configuration (permission
rules, `harness-perms--auto-allow-tools`,
`harness-perms--inspection-tools`) and in the text agents read
about other sessions (`session_read`).  `harness-tools-label NAME`
returns the label, or NAME for a tool nobody registered.
`harness-tool-title NAME INPUT` titles a call: the label, then a colon
and the `:subject` of INPUT ("Read file: x.el"), or the label alone
when the subject is nil.  Without a `:subject` function, or when it
fails, the subject is the first line of the first string in INPUT.
Tool-call nodes, permission prompts, the activity of a running turn and
ACP `tool_call` titles all carry this title.

CTX = `(:session-id ID :cwd "/abs/" :host PREFIX :call-id "…" :report FN
:note FN)`.  `:report` accepts a string for progress, which the
activity line shows (its last line, `tools/progress'); `:note` accepts
a line or a few for people to read, which the chat shows under the
call's own block (`tools/note', see "The note under a running call"
below).  RESULT = `(:content "…" :is-error BOOL :attachments (…)
:images ((:path "/abs" :mime "image/png")…) :meta PLIST)`: `:attachments`
is what the chat shows the user, `:images` the pictures the model is to
see (read_file on an image gives both; the agent sends them on, see
agent), a list of files of type `image/png`, `image/jpeg`, `image/gif`
or `image/webp`; it survives the size guard and the filters (secrets
masking among them), which rebuild a result.  A handler can hand back a
raw byte in `:content` --
`cat` of a binary file, say, or a stuck transcript `session_read` or
`emacs_buffer` read back -- which `harness-tools--normalise-result`
repairs with `harness-valid-text` before anything truncates, saves,
records or sends it: a provider's wire protocol, and `json-serialize`
under it, refuses the whole message for one raw byte anywhere in it,
which otherwise leaves the model with no answer to its call at all.

- `tools/list &optional SESSION-ID` → TOOL-SPECs `(:name :label
  :description :schema :kind :coalescable)`, filtered through sync
  filter `agent/tools` (value: list of names; args: session).  Without
  SESSION-ID every registered tool: how UIs learn the labels.  A tool
  a plugin module defines (`harness-module-plugin-p` of its
  `harness-tool-module`) is for the sessions whose frozen plugin list
  names that module (`plugins/of-session`), once it is ready: any other
  session never gets it, and `agent/tools` never sees it for that
  session (`harness-tools--in-scope-p`; see Projects' plugins).
- `tools/execute SESSION-ID CALL` (CALL = `(:id :name :input)`) → promise of
  RESULT.  Pipeline: lookup → `permission/decide` (async filter) →
  handler (with `harness-tools--timeout`) → sync filter `tools/output`
  → context-bomb guard → sync filter `tools/result` → events
  `tools/started`, `tools/finished`.
- Sync filter `tools/output` (value: the RESULT; args: session id, CALL)
  is what a tool returned, before anything keeps it, and it runs ahead
  of the size guard so that the file an oversized result is saved to
  holds what the filter let through.  Sync filter `tools/output-text`
  (value: a string; args: session id) is every other text a tool or
  the agent hands on from a call: what `:report` and `:note` announce
  (`tools/progress`, `tools/note`), the message of a tool that failed,
  and the output of a call a provider ran itself
  (`harness-agent--record-builtin-result`).  The secrets module is the
  filter on both, and masks secrets in them (see secrets).
  `tools/execute-approved` runs both as well.  A filter that signals is
  skipped by `harness-run-filter`, so a filter that has to hold text
  back catches its own errors and returns something safe in its place.
  The lookup fails, "Unknown tool NAME. Available: …", for a tool
  nobody registered and for a plugin's tool called from a session
  whose list does not name its module.
- `tools/note SESSION-ID CALL-ID TEXT` is what a running call says of
  itself beyond its one progress line: a line, or a few, for people to
  read, which the agent keeps on the call
  (`harness-agent--calls` `:note') and the chat draws under the call's
  block.  The handler emits it with `harness-tools-note' on CTX's
  `:note'; `harness-tools-watch-session' composes the notes of the
  calls that show a session (see "The note under a running call"
  below).  The whole note travels -- it may hold newlines -- where
  `tools/progress' keeps only its last line for the activity line.
- `tools/builtin SESSION-ID` returns the names of the harness tools
  that the session's provider runs a tool of its own for, and
  `tools/list` leaves them out.  They must be in the provider's
  `:builtin-tools` capability, among the tools the session gets
  otherwise, and picked by sync filter `agent/builtin-tools` (value:
  list of names, initially nil; args: session, the names the provider
  offers); tools-web picks web_search (see below).  The agent passes
  them in the request's `:builtin-tools`.
- `tools/authorize SESSION-ID CALL` (CALL = `(:id :name :input :kind)`)
  returns a promise of the DECISION on a call the provider runs itself.
  It comes from the same `permission/decide` chain as `tools/execute`,
  judged as a call of the harness tool NAME (its kind and paths; else
  CALL's `:kind`, else exec; the REQUEST carries `:builtin t`), and
  nothing runs.  Emits `permission/decided`.  The `:behavior` is allow
  or deny; a denial carries `:message`, the text `tools/execute` would
  have returned.
- `tools/execute-approved SESSION-ID CALL` runs CALL with no permission
  check at all, for a call the user approved by hand after the chain
  denied it (`rerun_approved` in harness-perms.el): their approval is
  what the chain would have asked for, and the input CALL carries is the
  very input it was denied with.  The result is truncated and given to
  the `tools/result` filter as `tools/execute` gives one, but nothing is
  announced as `tools/started` or `tools/finished`: the call is no call
  of the session's own turn, the `rerun_approved` call that runs it is,
  and its progress and notes show under that call.
- Corporate mode (`harness-corporate-mode`) turns off the tools of kind
  `net` other than web search (`harness-tools--corporate-net-tools`:
  web_search), and ssh, of kind `exec` but run on another machine
  (`harness-tools--corporate-remote-tools`).  No session gets them; the
  list without a session still has them.  `tools/execute` and
  `tools/authorize` deny a call of kind `net` to any other tool (one the
  harness lacks included), and a call of ssh, before the
  `permission/decide` chain, whatever the mode and the standing rules:
  reason "corporate mode: network tools other than web search are
  off" (for ssh "corporate mode: tools that reach other machines are
  off"), a hint to work with the project and the tools the session has,
  `:denied t`, and `permission/decided` as for any decision.  TRAMP
  paths stay as they are: a remote session's host, and a host a tool's
  path names, are reached once the jail lets them be.
  web_search stays, and so does a provider's own search standing in
  for it (`tools/builtin`); their calls go to the chain as in any mode.
- Context bomb: outputs over `harness-tools-max-output-chars` (30000) are
  saved, as `tools/output` left them, to
  `harness-state-directory/outputs/CALL-ID.txt` and replaced by the head
  plus an instruction to range-read that file.
- A handler that signals, or whose promise rejects, fails the call
  with "Tool NAME failed: MESSAGE" -- unless TRAMP could not reach the
  host the call is about (the first of its `:paths` on another host,
  else the session's cwd): a file error, or the end of input TRAMP met
  reading the answer to a prompt, while TRAMP has no connection to
  that host.  Then `harness-tools-remote-failure PREFIX ERR`, which the
  ssh tool uses for its own connections too, says why: "Could not
  connect to /ssh:box: (REASON)." with what `ssh -o BatchMode=yes` says
  run once more (no such host, a refused key, an unknown host key, a
  passphrase prompt) and, for a host ssh logs in to on every hop, how
  to set the host up; `:meta` is `(:host PREFIX :connected nil)`.  A
  connection TRAMP refused because another call was using it is
  reported as busy, to be made again (`:meta` `(:host PREFIX :busy t)`).
- Denied calls return `(:is-error t :denied t :content "Denied: REASON. HINT")`.
  Every denial is kept per session under the handle of the call's id,
  and the reason names the handle and says the user can approve the call
  in the chat (see the perms section, "Denied calls the user can
  approve"): the agent can then run it unchanged with `rerun_approved`.
  The agent keeps `:denied t` in the `:meta` of the call's tool-result
  node, so a view can tell a call the permission system refused, which
  never ran, from one that ran and failed (`harness-ui-tool-outcome`);
  the user's approval and the rerun are written there too, where the
  views show them and a reload keeps them.

### perms

Async filter `permission/decide`: value is a DECISION
`(:behavior allow|deny|ask :reason "…" :input UPDATED :final BOOL)`,
args are the REQUEST `(:session SESSION :tool NAME :input PLIST :kind KIND
:paths (…))`.  Chain (priority): 4 access gate (the access module: a
tool turned off for the session, or one that would reach the network in
a session that gave it up, is denied for good, `drop_access` is allowed
for good (whatever it gives up, a Linux capability of the commands
included), and a write to a `.dir-locals.el` asks the user; see
access), 5 dir-request, 5 escalation (the access module:
`request_escalation`, decided only by the user, as
`request_directory_access` is, a capability included), 6
away-request, 6
session-move (the session tools: the user confirms every
`session_move`), 7 sandbox-guard, 8 supervisor (the supervisor module,
a plugin's stage: a session in supervisor mode is denied, for good, a
call to any tool off its allowlist, in every permission mode; see
supervisor), 10 jail, 20 mode, 25 write-up (the tasks module: a backlog
write-up only reads), 28 supervisor approval (the supervisor module,
also a plugin's stage: a supervising session's `submit_plan` and
`retry_step` stay `ask` in ask mode with the user present and are
allowed otherwise, so the judge never rules on a plan; see supervisor),
30 auto (LLM judge), 40 non-interactive, 90 ask-user (turns `ask` into a
pending request and resolves when answered).  A judge denial reaches 90
as an `ask` in an interactive session, so the user answers it; in a
non-interactive session it stays a denial.

Who decided a call is kept with the decision.  `harness-tools--decide`
runs the chain traced (`harness-tools-decide-traced`, over
`harness-run-filter-async-traced` in the core): the decision gets
`:stage`, the label of the last stage that changed it, from that stage
function's `harness-permission-stage` property (`jail`, `mode`, `judge`,
`access`, ...).  A stage that knows better says so itself with `:by`:
`user` for a decision the user's answer made, `rule` for a standing
rule's, `mode` for the mode's, `away` for a denial because nobody can
answer.  `harness-tools-decision-by DECISION` gives `:by`, else the
stage's label, else `gate`; the access module's judgements and the
`permission/decided` event carry it.

- The away-request stage owns the decision of the `set_non_interactive`
  tool (tools-sessions), as the dir-request stage owns
  `request_directory_access`'s: always final, so the mode, standing
  rules, `harness-perms--auto-allow-tools` and the judge never see it.
  Turning the mode off (`enabled` false) only brings the user back in
  and is allowed at once.  Turning it on asks the user, in every mode,
  auto and yolo included: a `permission` prompt titled "Turn
  non-interactive mode on for TARGET" (this session, session REF, or
  every current session and task of every project) with the agent's
  reason and the options `harness-perms-away-options` (allow-once,
  deny-once).  Its `harness-perms--waiting` entry is `:user-only`, so
  `permission/answer` decides that call alone and records no rule
  whatever the scope (`harness-perms--answer-user-only`), and neither a
  switch to yolo nor one to non-interactive answers it.  A
  non-interactive session, or a harness without sessions to ask in, is
  denied at once with a hint not to ask again, and the agent gets no
  steering message after it (see non-interactive below): there is no
  other way to reach that goal.

- `session_settings` (tools-sessions) is weighed per call
  (`harness-perms--call-kind`): `action=read` shows a session's settings
  and changes nothing, so it is a read -- ask mode and accept-edits
  allow it as any other read inside the roots, and no judge sees it --
  while `action=set` changes harness state and keeps the `meta` its tool
  declares, so ask mode asks the user about it (stage 90) and the judge
  weighs it in auto mode and in a non-interactive session, the same guard
  `session_send` and `session_control` get.  A standing rule comes first
  and can allow or deny either (`harness-perms--rule-matches-p` weighs
  the same kind).  The tool is declared `meta`, not `read`, so that a set
  would ask even were the classification ever missing, and it refuses the
  permission mode, non-interactive mode, allowed directories, the working
  directory and the host, naming the tool that changes them.

- The sandbox guard asks `sandbox/check-command` about every `exec` call
  whose input has a `:command` (the bash tool), passing the directory it
  runs in and the session's own worktree (`:worktree`, else `:cwd`).  A
  refusal is a final deny, in every mode, yolo and standing rules
  included: the command would do damage only because it runs sandboxed
  (see sandbox).  A guard that fails lets the chain go on.

- `permission/answer SESSION-ID PENDING-ID ANSWER` — ANSWER
  `(:behavior allow|deny :scope once|session|always :reason :pattern)`,
  or an option id string such as "allow-session" (what ACP clients send
  back), also as `(:option ID :pattern P)`.
- Patterns: a prompt about a path outside the roots (the jail's, or an
  agent's `request_directory_access`) is answered for a glob pattern,
  not for one file.  Its payload's `:pattern` is everything in the
  directory it asks for (`DIR/**`), with symbolic links resolved.  For
  the jail's prompt that is the root of the repository the path lies
  in (`harness-perms--prompt-dir`: the closest directory holding it
  with one of `harness-perms--repository-markers`, `.git` and the
  like), so one answer opens the project or package an agent finds its
  way around; an agent reading a configuration used to be asked about
  each directory of it it reached.  The directory holding a file, or a
  directory itself, when there is no root, it is `/`, is or holds the
  home directory, or holds the session's cwd or worktree (the main
  checkout of a worktree), and for a remote path (the repository root
  is not looked for there).  For an agent's
  request it is the directory asked for.  No other prompt
  carries one (see the tool prompt below).  ANSWER's `:pattern`,
  absolute or relative to the session's cwd, replaces it: more specific
  (`DIR/sub/**`, `DIR/*.el`, one file) or less (a parent).  Roots and
  rule paths alike are directories, holding themselves and all below,
  or globs, which have a `*` or a `?` (`*` within a name, `**` across
  directories, `**/` also none, `?` one character;
  `harness-glob-regexp` in harness-util, shared with the glob tool),
  matched case-sensitively against resolved paths by
  `harness-perms--within-p`.  Brackets are no classes there: they match
  themselves, so a directory such as `Photos [2024]` stays a directory.
  `DIR/**` also holds DIR itself, and a glob ending in `/` holds
  everything below the directories it matches.  A grant of `DIR/**` is
  kept as the directory DIR/, so default grants read as before; a grant
  narrowed to one file keeps its name.
- Paths on another host (TRAMP names), and the login's home directory
  there.  Nothing in the chain may connect to a host -- not to expand a
  path, not to ask for its home directory, not to learn whether a
  connection is open -- and only the host knows where its login's home
  directory is, so a call that runs there (the ssh tool without an
  absolute cwd, `read_file /ssh:box:~/notes`) is about a place the
  harness can name and not find, written as TRAMP writes it:
  `/ssh:box:~/`, `/ssh:box:~/src/`.  Such a name (`harness-remote-home-p`)
  is a place of its own and is never expanded, because `expand-file-name`,
  `file-truename`, `file-in-directory-p` and `abbreviate-file-name`
  (it asks whether the file system is case sensitive) all connect to the
  host for it, expanding its local part as a local name gives the home
  directory of THIS machine's user, and `file-remote-p` expands it too once
  TRAMP is connected to the host.  So harness-util.el reads such names
  without expanding them (`harness-remote-parts`, from
  `tramp-dissect-file-name`; jump hosts stay in the prefix),
  tidies their `.` and `..` by text (`harness-remote-home-tidy`: `~/a/../b`
  is `~/b`, and a `..` that leaves the home has no name), and offers
  `harness-file-remote-p`, `harness-absolute-file-name` and
  `harness-abbreviate-file-name` for `file-remote-p`,
  `expand-file-name` and `abbreviate-file-name`; the permission
  chain, the access module and the pending panels use those on every path
  that may be a request's.  The tools' own handlers still use
  `harness-tools-resolve-path` (they run once the call is allowed and
  connect for the real directory); the request's `:paths` are made by
  `harness-tools--request-path`, which does not (so `read_file
  /ssh:box:~/x` no longer connects while it is being decided).
  `harness-perms--within-p` compares by place: a root in a home
  directory holds what lies in the same home (the local parts below the
  tilde are compared as they are for any remote path, `~bob` being
  another home); a root elsewhere on the host holds a path in a home only
  if it holds the whole host, `/ssh:box:/` or `/ssh:box:/**`, the grant
  older prompts offered, so those keep working and `/ssh:box:/home/u/`
  does not (the harness does not know that is the home); a root in a home
  never holds an absolute path; and a path whose `..` leaves the home is
  held by roots for the whole host only.  Deny rules therefore deny
  exactly what they say.  The ssh tool's jail path is the home directory
  for a call with no cwd, a relative one or one starting with `~`
  (`harness-tools-ssh--home-path`: `~/a/../b` is `~/b/`), the host's root
  for a cwd that leaves the home or is another user's, and the
  directory itself for an absolute one.  The jail prompt for a home
  path says what it is -- title `Access /ssh:box:~/ (the login's home
  directory)`, reason `SSH wants /ssh:box:~/ (the home directory of the
  login on box, where ssh starts), which is outside the allowed
  directories`, a non-interactive denial and its hint name the same
  directory -- and is answered for `/ssh:box:~/**` by default;
  the lines of its patterns go from the path itself through its parent
  directories (the home directory after those in it) to the host's whole
  file system, `/ssh:box:/**`, the widest and last
  (`harness-ui-pending--pattern-suggestions`, shown with the notes `home
  directory` and `whole host`).  `request_directory_access` for such a
  path asks the same way.
- What a shell command reaches: the bash tool's `:paths` is where it
  runs, which is all the jail checks (the sandbox confines the command,
  and the mode and the judge read it whole).  For an `exec` call with a
  `:command`, `harness-perms--command-paths` reads the paths the
  command line names from the same syntax tree that scopes a lasting
  answer (`harness-perms--shell-ast`, see below): every command the
  line runs, in a pipeline, a list, a subshell or a substitution,
  contributes its `:path-words` (its words less the programs and the
  wrappers that run them), and a redirection's target is a path
  wherever it stands.  It keeps words that are absolute, start with `~`
  or `$HOME`, or with `./` or `../`, and the values of `--option=…` and
  `NAME=…` words;
  not `/dev/null` and the like, and on this machine not an absolute word
  whose first directory does not exist, so a `/api/v1` in a grep is no
  path (on a remote host nothing is looked up, and `~` words are left
  out).  A command that runs in a home directory of a host
  (`/ssh:box:~/src/`) has its relative words in it (`./a.el` is
  `/ssh:box:~/src/a.el`, made by text and never with this machine's home
  directory), and one that leaves it (`cat ../../x`) names the root of
  the host, `/ssh:box:/`, which only a grant of the whole host holds.
  A here-document's body is data, not paths.  The paths are on
  the host the command runs on, its
  directory's: the session's for bash, the ssh tool's host for ssh.  The call is about its subject paths
  (`harness-perms--subject-paths`): the ones it names outside the
  session's directories, or, when it names none there, where it runs,
  as before.  The tool prompt shows them, so `ls -la
  ~/.claude/projects/x` run in the project names `~/.claude/projects/x`
  and not the project (being about the call, it offers no pattern, see
  below), and the rules weigh them (below).
- The jail asks instead of denying when a path lies outside the roots
  and someone can answer: a pending `permission` request whose payload
  carries `:dir`, `:pattern` and the options allow-once (this call may
  reach the pattern) / allow-session (grant the pattern to the session)
  / allow-always (add it to `harness-allowed-directories`) / deny-once
  / deny-always (a standing rule `(:path PATTERN :behavior deny)`, for
  every tool).  After a grant the rest of the chain still decides the
  call itself; a pattern that leaves the call's path out makes the jail
  ask again.  A rule that denies the call anyway denies it at once,
  without asking.  Non-interactive sessions are denied with a hint as
  before.  The prompt names the directory with symbolic links resolved,
  since that is what the jail compares and what a grant opens.
- Agents ask for a directory themselves with the `request_directory_access`
  tool (`path`, `reason`).  The dir-request stage owns that tool's
  decision and always makes it final, so the mode, standing rules,
  `harness-perms--auto-allow-tools` and the auto judge never see it.
  In every mode, auto and yolo included, a directory is granted only
  by a person answering the prompt.  A directory that is already
  reachable is allowed at once and nothing is granted.  Non-interactive
  sessions are denied with a hint, and so is a directory a path rule
  for no tool in particular denies (`harness-perms--dir-rule`, what
  deny-always records); no rule grants one.  Otherwise the session
  blocks on a `permission` prompt (`:dir`, `:pattern`, the agent's
  reason, and the five options every request has,
  `harness-perms-dir-request-options`).  There is no single call to let
  through, so allow-once grants the pattern until the session's turn
  ends (`harness-perms--grant-for-turn`): a root of source `turn`,
  listed and revocable as a session grant is, never stored, and dropped
  on `agent/turn-ended` and on `agent/turn-started`
  (`harness-perms--end-turn-grants`, so one made after its turn was
  cancelled does not reach the next).  allow-session grants it to the
  session, allow-always to every session, and the denials are the jail
  prompt's.  The
  decision hands the handler the grant as `:granted` in its `:input`,
  and the handler tells the agent what it can reach, saying so when the
  user granted another pattern than it asked for.  Being a permission
  and not a question, the
  prompt cannot be answered by another agent through `session_control`.
  The auto judge is also told to deny calls that widen the agent's own
  permissions some other way (for example `harness-allowed-directories`
  in `.dir-locals.el`, the permission mode, or the sandbox).
- Confirmations: some calls change what only the user may change,
  whatever the mode, the standing rules and the judge would say.  The
  tool's own stage, ahead of the jail, has the user confirm each with
  `harness-perms-confirm REQUEST NEXT &rest PROMPT` (`:title`, `:reason`,
  `:paths`, `:input` the handler gets once the call is allowed, `:hint`
  for the agent after a no): a `permission` prompt whose payload has
  `:confirm t` and offers allow-once and deny-once only
  (`harness-perms-confirm-options`).  The answer is final and records no
  rule, whatever scope it names; switching to yolo or to
  non-interactive does not answer it;
  a non-interactive session, or one nobody can answer for, is denied at
  once with a hint to say in the answer what the agent wanted done.
  `session_move` is such a call (stage 6, `harness-tools-sessions--move-gate`):
  a move changes the directories a session may reach.  The prompt says
  what `session/move-check` says of the move (from where to where, the
  project, whether it waits for a turn to end, whether the old
  directory stays allowed, the agent's reason), and the stage hands the
  handler the move the user confirmed, the directory absolute, marked
  with an uninterned symbol no model input can carry: the handler moves
  nothing else.  A move that cannot be made asks nobody and fails in the
  handler with the reason, so it is no denial; nor does moving a session
  back to where it works, which only cancels the move it waits to make.
  The calling session moving itself moves when its turn ends, and its
  new directory is granted until then (`permission/allow-dir` scope
  `turn`).
- The roots of a session are its cwd, its worktree, its own temporary
  directory (`session/tmp-dir`, asked for on every look at the roots, so
  it exists whenever the jail lets a call into it), the configured
  `harness-allowed-directories`, its grants (to the session, and until
  its turn ends) and the tool output directory.  The temporary
  directory needs no grant and cannot be revoked.  They are entries
  `(:dir :source)` (`harness-perms-dirs`), run through the sync filter
  `permission/dir-entries` (value: the entries; argument: the session)
  and then made unique: the access module takes out the ones a session
  gave up and adds those it may only read, `(:dir D :source read
  :read-only t)`.  `harness-perms-roots` are the entries that may be
  written; `harness-perms-read-only-dirs` the `:read-only` ones, which a
  call of kind `read` may reach (`harness-perms--read-only-reachable-p`)
  and any other call is jailed out of as outside the roots, the jail
  asking the user as it does there; `harness-perms-readable-roots` both.
  The sandbox shows a `:read-only` entry to bash read-only.
- Inspecting the harness itself is one of the things that make it
  powerful, so no mode, judge or jail stands in its way.  The harness
  is no root, but a call of kind `read` may read it, in every mode,
  with the user there or away: `harness-perms-inspection-dirs` lists
  `harness-directory`, the checkout its harness.el links into when it
  is a symbolic link (a straight.el build directory links every source
  into the package's repository), and `harness-state-directory` (the
  sessions with their transcripts, the task boards, usage).  The jail
  lets such a read through (`harness-perms--inspectable-p`) and the
  mode stage allows it with no judge asked ("reading the harness itself
  never needs approval"); a standing rule still decides first.
  Writes, commands, sub-agents and directory grants there are jailed as
  anywhere outside the roots, and their denial says reading needs no
  grant.  The credentials in the state directory
  (`harness-perms--private-files`: `acp-token`, and `server-config.el`
  with the API keys forwarded to the harness process) are left out,
  since what a tool reads goes to the model's provider; so is a search
  below a directory that holds them, which the tools that only list
  names (`harness-perms--listing-tools`: list_dir, glob, file_info) may
  still look at.  Symbolic links are resolved first, out of the harness
  as much as into it.
- Skills are read the same way.  Agents read a skill's files directly
  (a SKILL.md whose place they know, the files `skill_load` lists), and
  a prompt about `~/.claude/skills` used to stop an unattended task in
  needs-input.  `harness-perms-skill-dirs` asks the skills module
  (`skills/directories`) which directories discovery reads for the
  session's cwd; a call of kind `read` may read the `:contained` ones
  in every mode, with the user there or away.  The jail lets such a
  read through (`harness-perms--skill-readable-p`) and the mode stage
  allows it with no judge asked ("reading skills never needs
  approval"); a standing rule still decides first, and the harness's
  credentials stay out.  Writes, commands, sub-agents and directory
  grants there are jailed as anywhere outside the roots, and their
  denial says reading needs no grant.  Where reading does not fit, the
  jail refuses at once, final in every mode and with the user there
  too, and nobody is asked (`harness-perms--skills-refusal`): a path in
  a skills directory as written that symbolic links lead out of what
  may be read (a link to a file elsewhere, a project's `.claude/skills`
  linked out of the project), a path in a remote session's skills
  directories (its host's, not the skills the harness serves; the same
  path as a local one, or the same place under a home directory there,
  `~/`, `/home/USER/`, `/Users/USER/` or `/root/`), and a path in one
  that a shell command run in the sandbox (`sandbox/confined-p`) names
  but the sandbox does not show.  The refusal's hint
  (`harness-perms-skills-hint`) points to `skill_search` and
  `skill_load` (with `file` for a supporting file), which never need
  approval, and to `request_directory_access` should the task need the
  target directory itself.  No mode stage was added: the jail and the
  mode stage do it, as for the harness.
- A file the user's Emacs showed a definition in is read the same way.
  emacs_find_definition, an inspection tool, shows a definition's
  source and names its file; the agent then reads the code around it,
  and asking about that file asked again about what the inspection
  showed.  The tool reports the file (`permission/reveal-file
  SESSION-ID FILE`, for a local regular file, a definition it found in
  a file and did not print), which records it, symbolic links
  resolved, for the session in memory (`harness-perms--revealed`).  A
  call of kind `read` may then read it, in every mode, with the user
  there or away: the jail lets it through
  (`harness-perms--revealed-p`) and the mode stage allows it ("the
  user's Emacs showed a definition in this file; reading it never
  needs approval").  Only the file: its directory, a write or a
  command there are jailed as before, a standing rule still decides
  first, and the harness's credentials stay out.
- `permission/allow-dir SESSION-ID DIR &optional SCOPE` (SCOPE `always`
  grants every session, `turn` the session until its turn ends, as
  allow-once does for `request_directory_access`), `permission/revoke-dir SESSION-ID DIR`,
  `permission/dirs SESSION-ID` (`(:dir :source cwd|worktree|tmp|config|session|turn|outputs
  :revocable :read-only)` plists, for the access view), `permission/allowed-dirs SESSION-ID`
  (the full effective root list: the entries a call may write), `permission/rules SESSION-ID`
  (`(:mode :non-interactive :auto-allow :session :always :roots :inspect :skills)`:
  `:auto-allow` holds the inspection tools too, `:inspect` the
  directories of the harness itself and `:skills` the skills
  directories every call that only reads may read),
  `permission/pending SESSION-ID`, `permission/reveal-file SESSION-ID
  FILE` (see above).
- Session directory grants are stored on the session record
  (`:allowed-dirs`), so they survive restarts and forks inherit them.
- Rules are plists `(:tool NAME-or-nil :kind KIND-or-nil :path PATTERN-or-nil
  :commands COMMANDS-or-nil :input ARGUMENTS-or-nil :behavior allow|deny)`;
  session rules live in memory, always-rules in `harness-perms-rules`.
  A rule with `:input`, a plist of arguments such as `(:command "make
  test")`, applies to a call that passes each of them with the very same
  value (`equal`), its other arguments free, allow and deny alike
  (`harness-perms--input-matches-p`); an `:input` that is no plist of
  keyword arguments holds no call, so a rule that is broken is never one
  that holds every call.  A rule with a
  `:path` (absolute, or relative to the session's cwd) applies to calls
  with paths only: an allow rule when the pattern holds every path of
  the call, a deny rule when it holds any.  For a shell command an allow
  rule needs every subject path (the ones it names outside the session's
  directories, else where it runs), so a rule for the project no longer
  lets `rm -rf ~` run in it; a deny rule holds when any path it names,
  inside or out, or where it runs lies in the pattern.  A rule with
  `:commands` applies to shell calls only, by what their command lines
  run: each command pattern is a program or a list of words from the
  program on (`("gcloud" "compute")`, `("gsutil")`); an allow rule needs
  every command the line runs to match one pattern, a deny rule any one.
  Commands are read from the command line's syntax tree
  (`harness-perms--shell-ast`): pipelines, lists, subshells, `if`,
  loops, `case`, command substitutions and the command after a wrapper
  such as `sudo`, `env` or `xargs` all count, while assignments,
  redirections, here-document bodies and comments are no commands.
  The paths a call names (`harness-perms--command-paths`) and the
  read-only cloud queries the mode stage allows
  (`harness-perms--read-only-cloud-p`) are read from the same tree, so
  one reading of a command line decides what a lasting answer covers,
  what a path rule sees and what needs no judge.
  The mode stage checks the rules first, before the auto-allow list and
  the mode.
- What a lasting answer covers is the user's to say: a tool prompt (the
  mode asking, or the auto judge objecting) is about the call itself,
  whose paths the jail already let through, so it offers no pattern but a
  **ladder of covers** (`harness-perms--cover-ladder`), from the narrowest
  to the whole tool, and its allow-session / allow-always / deny-always
  answers record `(:tool NAME COVER... :behavior B)` for the step the
  answer names, a `:pattern` in the answer notwithstanding.  The steps,
  narrowest first, with the ids and labels the prompt lists (a label says
  what the step leaves free, so that "all calls of the tool" and "some
  arguments of them" read differently):
  - a shell call (a `:command` the reader can read):
    `exact` `(:input (:command "gcloud compute instances list --project
    p"))`, "every bash call whose command is exactly ..." (the command's texts and
    not its numbers, so a timeout does not make it another call);
    `subcommands` `(:commands (("gcloud" "compute" "instances")))`, the
    programs with the words the line's commands share, up to three and
    never an argument ("every gcloud compute instances call (any
    arguments)"); `commands`, what an answer always held for when it
    differs from the steps around it (a line with several commands of one
    program and one command of another); `programs`
    `(:commands (("gcloud")))`, "every gcloud call (any arguments)";
    `tool`, "every bash call (any command)".  A pattern is a prefix: it
    holds every later command that starts with those words, `gcloud
    compute instances delete` included, never the arguments the call
    happened to pass, which only `exact` pins.  Commands come from
    `harness-perms--command-groups`; steps that hold the same calls are
    one, named for the widest (`ls -la` has `exact`, `programs`,
    `tool`).  A line the reader cannot read has `exact` and `tool`;
  - a shell call on a host -- the ssh tool (its `:host` argument, as the
    agent wrote it), or bash in a TRAMP directory -- has those steps
    for that host first, ids `host-subcommands`, `host-commands`,
    `host-programs` and `host-tool`, labelled `... on HOST (any arguments)`
    and `every ssh call on HOST (any command)`, recorded with
    `(:input (:host "admin@laptop-0:4358"))` for ssh and with
    `(:path "/ssh:box:/**")` (the host's whole file system) for bash, and then
    the programs and the tool for any host (`programs`, `tool`, labelled
    `(any host, any arguments)` and `(any host, any command)`).  The
    prompt starts on the programs of the host, so "Always allow" on
    `journalctl -u k3s` run on a host covers journalctl there, where it
    used to cover journalctl on every host the agent would ever name;
    a command the reader cannot read starts on `host-tool`.  A rule for one
    host does not match a call that spells the host differently; that
    asks again.  The rule's subject reads `ssh (journalctl and tail) whose
    host is exactly "admin@laptop-0:4358"`;
  - a call that reads or writes files: `path` `(:path "/p/lisp/a.el")`,
    `dir` `(:path "/p/lisp/")`, `project` `(:path "/p/")` (the session's
    working directory or worktree, when the file lies below it) and
    `tool` ("every edit_file call (any path)"); a call on several
    files has the directory that holds them all, never the root of a
    file system, and files on different hosts only the tool;
  - any other call: `exact` `(:input ARGS)`, when its arguments are few
    and each a text or a number ("every web_fetch call whose url is
    exactly ..."), and `tool`.
  The prompt starts on the step an answer always held for -- for a
  shell call the one `harness-perms--command-rule-prefixes` gives
  (`programs` for a single command, the words commands of one program
  share when there are several), `tool` for any other call and for a
  line the reader cannot read -- so nothing changes unless the user
  chooses; with
  `harness-perms-default-cover` set to `narrowest` (the setting for
  least privilege first) every ladder starts on its first step instead.
  `permission/answer`'s `:cover` names the step (a string); one that
  names no step of the ladder, or none, is the step the prompt started
  on, so a client that knows nothing of covers answers as before.
- Events `permission/requested SID PENDING` (PENDING `(:id :kind permission
  :payload (:tool :input :kind :paths :call-id :title :options :ladder
  :cover))`, `:ladder` the covers a lasting answer can hold for, narrowest
  first, each `(:id :label)`, and `:cover` the id of the step the answers
  start on; plus `:dir`, `:pattern` and `:reason` for a directory prompt,
  and for a shell command `:commands` and `:covers`, the command patterns
  a lasting answer always held for and a few words for them ("gcloud and
  gsutil"); a tool prompt's `:paths` are its subject
  paths, and a shell command's prompt has `:cwd`, where it runs; a
  confirmation has `:confirm t` and its own `:reason`; UIs offer only the
  listed `:options`, show a pattern only when there is one, and word a
  lasting answer with the step of `:ladder` it is for when there is one,
  else with `:covers`),
  `permission/decided SID REQUEST DECISION`, `permission/dir-allowed SID DIR`,
  `permission/dir-revoked SID DIR` (a grant revoked, or one until the
  turn ends gone with its turn).
- Every request is answered with the same five options, whatever it is
  about: allow-once, allow-session, allow-always, deny-once and
  deny-always, named Allow, Allow for session, Always allow, Deny and
  Always deny (`harness-acp-permission-answers`, which both the UI's
  panels and the options of `session/request_permission` read).  What
  allow-once covers is the request's: the call, for a tool prompt; one
  call reaching the pattern, for the jail's prompt; the pattern until
  the turn ends, for `request_directory_access`.  A confirmation is the
  exception: it offers allow-once and deny-once only, for the call.
- An answer that lasts is noted in the session's transcript, whoever
  gave it (the chat, a popout, a view, an ACP client): a rule recorded
  (an allow or a deny for the session or always on a tool prompt -- for
  the cover the answer named: the exact arguments, a file, directory or
  project, the commands a shell call runs, or the whole tool -- a deny
  for the session or always on a directory prompt) or a directory
  granted (allow-session or allow-always on the jail's prompt or
  `request_directory_access`) appends a hint
  (`harness-perms--note-recorded`, through `session/append` before the
  call goes on, so it sits under the call) saying what, such as
  "Always allowing every bash call to gcloud and gsutil, in every
  session" (or "every bash call" for a whole-tool rule, "every bash call
  whose command is exactly "make test"" for exact arguments, "edit_file calls in
  ~/proj/lisp/" for a directory), with the record
  in its `:meta` `:permission` (see Node).  A rule or a grant that was
  there already gives a note with nothing to undo (no `:undo`, and the
  text says "already so").  allow-once records nothing and gives no
  note, the turn grant of the agent's own request included.  What a
  new note records is also a lasting decision of the kind `permission`
  (`decision/record`, see "decisions"), whose id the note's `:meta`
  `:decision` holds: undone and redone by id, from any session.
- `permission/undo SESSION-ID NODE-ID` → `(:outcome undone|changed|gone|none
  :message "…" :decision DECISION)` takes back what note NODE-ID
  recorded and nothing else: the decision on the call it answered
  stands.  With the decisions module it is `decision/undo` of the
  note's decision; a note written before decisions were kept is taken
  in first (`decision/record` with what its `:permission` says, the id
  then written into its `:meta`).  It marks the note
  (`session/update-node`, `:undo` OUTCOME and `:result` the message),
  and a note tried already returns what it got and changes nothing
  (`none` for one with nothing to undo).  A rule is looked up
  by value, the rule as recorded first, then one equal in substance
  (`harness-perms--rule-key`: tool, kind, path, commands, behavior and
  arguments, compared trimmed and with symbols as strings and command
  patterns and arguments in a settled order, so a rule Settings saved
  back still counts);
  `undone` removes it from the session's rules or from
  `harness-perms-rules`, saved.  A rule for the same tool, path,
  commands and arguments that says something else since (edited in
  Settings, say) is
  `changed` and stays, and with none left the outcome is `gone`;
  session rules live in memory and a fork starts without them, so that
  is what a session note gets after a restart, or in a fork, which
  copies the note.  A
  directory: the entry recorded, or one that expands to it, is removed
  (`permission/dir-revoked`); an entry that still covers it, a parent
  put in its place say, is `changed` and stays; else `gone`.  The
  message says what happened and why.
- `permission/redo SESSION-ID NODE-ID` → the same plist: `decision/redo`
  of what note NODE-ID records, once undone.  It records the rule again
  (`harness-perms-add-rule`) or grants the directory again
  (`permission/allow-dir`) while nothing took its place: no rule for the
  same tool and path, no entry that covers the directory, the session
  a session-wide answer was for still there, and the policy not setting
  the list.  (The same tool and path above also means the same
  commands and arguments: two rules for one tool that differ in what
  they cover are two rules.)  Otherwise the decision ends `changed` (or `gone`, its
  session gone) and the setting stays as it is.  The note is `offered`
  again once redone.
- A call denied by a rule a decision recorded names it: the rule
  decision of `permission/decide` carries `:decided-by ID`
  (`harness-perms--rule-decision-id`: the newest decision in effect for
  that rule, the session's own or one for every session), and once the
  call's result is in the transcript its `:meta` `:decided-by` says so
  (`agent/tool-result`, `session/update-node`).
- Denied calls the user can approve: every denial is kept, per session,
  under the handle of the call's id (`harness-perms--remember-denied`, a
  `permission/decided` subscriber, so a denial is kept whoever made it,
  the jail, a gate, the judge or an answer), with the tool, the input
  exactly as it was denied, and the reason and hint the agent was given
  (`harness-perms--denied-record`).  `permission/approve-denied SESSION-ID
  HANDLE` → `(:handle :tool :approved :used :message)` is the user's
  approval of that one call, and only the user gives it: the chat's
  [Approve] button (`harness-chat-approve-denied-call` approves the call
  at point), a popout, or the ACP method.  It marks the record and the
  denied result node's `:meta` (`:approved`, `:approved-at`), which the
  chat draws and a session reloaded later reads, and prompts the
  session's agent with a system message: the user approved the call,
  rerun it unchanged with `rerun_approved`.  `rerun_approved HANDLE`, a
  tool in `harness-perms--auto-allow-tools` since its own handler is the
  check, takes the handle alone: the tool and its arguments cannot
  change.  It refuses a handle this session has no denied call for, one
  the user has not approved, and one already used (a handle is used
  once), and else runs the stored call through `tools/execute-approved`,
  which asks the chain nothing, marks the handle used and the rerun call
  (`:used`, `:rerun-call-id` under the call), and returns the call's own
  result with `:meta` `(:user-approved t :rerun-of HANDLE :rerun-tool
  NAME)`, so the transcript links the rerun to the call it was denied
  as and the chat marks it user-approved
  (`harness-chat--rerun-line`).  The record lives in memory for the run
  and in the session's transcript, where it outlives a reload: the
  call's node holds the tool and the input, its denied result the
  approval.
- Saving `harness-perms-rules` or `harness-allowed-directories` (an
  answer, `permission/allow-dir` with `always`, a revoke, an undo)
  emits `config/changed KEY VALUE global nil`, as the config module
  does, so an open settings page shows the change.
- Modes: `ask` (reads inside the jail allowed; everything else asks),
  `accept-edits` (reads/writes inside the jail allowed; exec/net ask),
  `auto` (reads inside the jail allowed; a cheap model,
  `harness-perms-auto-model`, decides the rest with a reason; falls back
  to ask).  The judge model defaults to `auto', which asks the session's
  own provider for its `:simple' tier (`provider/tier-model'), so a
  session on DeepSeek is judged by a DeepSeek model and one on Claude by
  Claude Haiku; a provider without tiers is sorted by price, and the
  session's own model is the last resort.  Naming a model, or nil for
  the session's own, overrides it.  `yolo` allows everything; the jail
  still applies.  Tools in
  `harness-perms--auto-allow-tools` are allowed in every mode: the meta
  tools, skill lookups, `web_search`, which only sends its
  query to the configured search provider, so task sessions can search,
  `notify`, which only reaches the user through the notification
  providers they set up, so unattended sessions can say they need them,
  and `hand_in`, which only records a task's report and ends the turn.
  So are those a module outside the harness adds to
  `harness-perms-extra-auto-allow-tools` (`harness-perms--auto-allow-p`),
  as the harness repository's plugin adds `open_harness`.
  So are the tools in `harness-perms--inspection-tools`, which only
  inspect the harness or the user's live Emacs: `emacs_buffers`,
  `emacs_buffer`, `emacs_windows`, `emacs_describe`,
  `emacs_find_definition`, `emacs_messages`, `session_info`,
  `session_list`, `session_read`, `session_search`, `session_history`,
  `session_wait`, `task_list`, `task_wait`, `notification_providers`,
  `watch_events` and `unwatch_events` (a watch only watches the
  harness's events, and wakes no session but its own).
  The model provider's own search, standing in for `web_search` (see
  `tools/builtin`), is decided as `web_search` too, so the same rules
  and the same auto-allow apply to it.
  `web_fetch` reaches any URL and stays with the mode (the judge in auto).
- Switching a session that waits on a `permission` prompt into `yolo`
  answers the prompt (a `session/updated` handler): answering it
  allow-once lets the call run, since yolo would have allowed it without
  asking.  Only what the mode stage now allows is answered, so a
  standing deny rule still decides; a directory prompt keeps waiting,
  because not even yolo grants a directory without the user, and so
  does a confirmation, which only the user gives.
- The judge is a safety check, not the agent's manager.  Its prompt
  (`harness-perms--judge-system`) has it decide one thing: whether the
  call risks serious harm that is hard to undo.  That means destroying
  data outside the roots, force pushes, system changes, sending secrets
  away, or widening its own permissions.  It leans to allowing:
  reads anywhere, edits, builds, tests, local git and scratch files
  anywhere (temporary directories included) are ordinary work, and so
  is inspecting the harness itself wherever it lives, with any tool,
  Emacs Lisp included, its credentials (`acp-token`,
  `server-config.el`) excepted: the judge sees only the inspection the
  rules above do not already allow.  It
  never rules on the task, its scope, its review or the project's
  workflow, and it is given nothing to rule on them with.  The user
  message (`harness-perms--judge-text`) holds the call alone: the tool,
  the first sentence of its description, the input, the working
  directory, the allowed roots and where the harness lives
  (`harness-perms--judge-harness`: its code and state directories and
  its credential files).  The request is `:ephemeral`, so the
  provider brings no earlier verdicts and no project instructions
  (CLAUDE.md).  It names its job, "Permission judge" ("Permission judge
  (retry)" for the second ask), with the session asking as `:job-parent`,
  so each verdict is recorded as an internal session under it (see
  "provider").  A judge's denial carries `harness-perms-judge-deny-hint`.
  A long input is cut (`harness-perms--judge-input-chars') and the block
  above it says so; the judge is told to weigh what the call would do,
  never whether a value looks complete, since a cut input once read as
  the agent's own truncated edit ("the replacement string is
  truncated ... that would corrupt the file").
- The judge follows what Claude Code's own auto mode follows: the
  `autoMode` block of Claude Code's settings.  Its `environment`
  entries name the organization's trusted infrastructure (source
  control, buckets, internal domains and services) and what it holds
  sensitive.  Its `allow`, `soft_deny` and `hard_deny` entries are
  prose rules.  Without them the judge is stricter than Claude Code
  with the same settings: to it the organization's own infrastructure
  is "off the machine", so pushes and uploads there that Claude Code
  allows are denied or put to the user.
  `harness-perms--judge-system-prompt` is now `:system`: the judge's
  prompt word for word, then, when there are any entries,
  `harness-perms--auto-mode-block`.  That block gives each list under
  what it means to Claude Code:
  - code and data sent to trusted infrastructure stay inside the
    organization, and so are not "sending private data off the
    machine"; secrets still go only to their own service, and a
    destination no entry names is judged as before;
  - a hard deny entry denies;
  - a soft deny entry denies unless an allow entry covers the call;
  - an allow entry lifts only soft denials.

  No entry lifts the judge's own rules.  In an interactive session, a
  soft denial that Claude Code would clear for the user's explicit
  intent reaches the user as any judge denial does.  The judge's hard
  rules count writing such rules into Claude Code's settings as the
  agent widening its own permissions.

  `harness-perms-claude-auto-mode-rules` reads the rules where Claude
  Code does:
  - the user's `settings.json` in `$CLAUDE_CONFIG_DIR` or `~/.claude`;
  - the managed sources in Claude Code's rank order: the server-managed
    cache (`remote-settings.json` there), the macOS configuration
    profile (domain `com.anthropic.claudecode`, read with `plutil`),
    then `managed-settings.json` and the `.json` files of
    `managed-settings.d` in the system directory (`/etc/claude-code`,
    `/Library/Application Support/ClaudeCode`, or
    `C:\Program Files\ClaudeCode`), merged in alphabetical order with
    hidden files left out.

  Of those sources it applies the highest-ranked one that holds a
  policy key, unless that one sets `managedSourcesBehavior` to
  `"merge"`, in which case it applies every one.  Each list holds the
  managed entries, then the user's, without `"$defaults"` (the
  judge's own rules stand in for Claude Code's built-in ones), blank
  entries or duplicates.  Project settings (`.claude/settings*.json`)
  are never read: a repository would be writing its own exceptions.
  Neither is the Windows registry.  Settings that cannot be read are
  skipped, and they never keep the judge from judging.
  `harness-perms-claude-auto-mode` nil leaves the judge its own rules
  only.  Managed CLAUDE.md files never reach the judge: its Claude CLI
  process runs with `CLAUDE_CODE_DISABLE_CLAUDE_MDS`, which keeps out
  every memory file, the managed one and policy `claudeMd` included.
- A judge denial is a verdict on one call, not on the work, so an
  interactive session puts it to the user instead of enforcing it
  (`harness-perms--judge-decision`): stage 30 hands on an `ask` that
  keeps the judge's reason and `:judge-deny', stage 90 opens the
  permission prompt (`harness-perms--judge-prompt-reason` words it as
  "The permission judge would deny this call: …"), and the user answers
  it like any other permission request: Allow (this once), for the
  session, or always.  Switching the session to yolo used to be the
  only way past a denial the user disagreed with.  A non-interactive session has nobody
  to ask: the denial stands and the agent is steered to another
  approach.  A judge that gives no verdict at all leaves the call `ask`
  as before, which the user is asked about in an interactive session.
- Jail denials are final and carry a constructive hint listing the
  allowed roots and how to widen them.  A path elsewhere in the
  system's temporary directory (and the agent's own request for one)
  also sends the agent to the session's own temporary directory, where
  scratch files go without stopping the session.  A path in the harness
  itself (and the agent's own request for one) adds that reading it
  needs no grant, and a read refused for reaching the credentials names
  them (`harness-perms--inspection-hint`); a path in a skills directory
  adds that reading it needs no grant (`harness-perms--skills-hint`).
- Non-interactive (the user is away) is no permission policy of its
  own and refuses nothing for being unattended: the auto judge
  (stage 30, `harness-perms--judge-p`) decides what would ask the user,
  in every mode, and its verdict stands.  The judge gets two calls:
  when the first ends at its output limit (`max-tokens`) without a
  verdict, which a reasoning model does after spending the small first
  budget thinking, stage 30 asks again with more room
  (`harness-perms--judge-retry-max-tokens') before it gives the call
  up; a verdict written before the cap is taken as it stands.  The
  judge asks for no extended thinking (`:no-thinking`), so the verdict
  is not left unwritten or half written behind the model's thinking.
  A call
  it gives no verdict on
  (it failed, timed out or answered without one; stage 30 passes the
  `ask` on with `:no-verdict` saying why) nobody can approve, so stage
  40 denies it, with that cause as the reason and a hint that this was
  no verdict on the call, which may be tried once more.  Directories are
  still granted by a person only: the jail and the dir-request stage
  deny.  After every denial in a non-interactive session, whoever made
  it, the `permission/decided` handler sends the agent a steering
  message (`harness-perms-steering-text`), once per call and only while
  a turn runs to take it, marked as from
  `harness-sender-system "non-interactive mode"`: the user is away, so
  respect the denial and reach the goal another way.  A refused
  `set_non_interactive` call is the exception: only the user turns the
  mode on, so there is no other way, and its hint says to carry on.
  The session's own `:non-interactive` switch decides, off as much as
  on.  It starts from `harness-non-interactive` when the session is
  created (an explicit false turns it off whatever the setting says);
  forks and sub-agents start with their parent's.  Changing the setting
  later leaves the sessions that exist alone.  The setting decides by
  itself only for a request without a session record.
  Switching a session to non-interactive (`session/updated` with a true
  `:non-interactive`, from `C-c h i`, the board, `C-c h I` or the
  tool) hands its waiting prompts to the judge from the command loop
  (`harness-perms--judge-waiting`): each prompt's request goes again
  through the stages from 11 to 89 (`harness-perms--redecided-stages`,
  with `harness-run-filter-async-between`), with the session as it is
  now, so it is decided as a new call of that session would be; an
  allow or a deny resolves the prompt and hands the call on, and a
  denial steers the agent as above.  The jail and the dir-request
  stage are not run again, and the prompts only the user answers
  (`harness-perms--user-only-p`: a directory, a confirmation, or
  turning non-interactive mode on) keep waiting.  A prompt answered meanwhile,
  or still undecided because the session turned interactive again,
  stays as it is.
- A policy ([policy.md](policy.md)) holds here too.  A permission mode
  or non-interactive switch it sets is every session's, whatever the
  session record says (`harness-perms--mode-of`,
  `harness-perms--non-interactive-p`).  When it sets
  `harness-perms-rules`, those rules are weighed before the session's
  own (`harness-perms--rules`), so no answer overrides them; prompts
  offer no allow-always or deny-always, and an answer for always given
  anyway holds for the session (`harness-perms--scope-allowed`).  When
  it sets `harness-allowed-directories`, no directory prompt offers
  allow-always, `permission/allow-dir` with SCOPE `always` is refused,
  and the global entries are not `:revocable`; grants for the session
  or the turn, which a person answering makes, stay as they are.

### access

What a session may reach, gathered in one place and set up per session
beyond its directories (harness-access.el, a core module, with its UI
half `ui-access`, the access view).

- The access profile is the session's ext `:access`, a plist of
  `:network` (`:false`: no network), `:read-only` (t: no writing),
  `:tools-off` (names), `:read-dirs` (directories it may only read),
  `:dropped` (directories it gave up: its cwd, worktree, temporary
  directory or one of `harness-allowed-directories`, for this session
  only) and `:caps` (the canonical names of the Linux capabilities, such
  as `CAP_SYS_PTRACE`, the user gave its bash and elisp commands, in the
  order given).  `:caps` is a grant where the others restrict:
  `harness-access--normalise` stores it only when it has names (once
  each), and a profile of it alone is a profile -- the stages that
  return early for a session without one still pass its calls and its
  tools on.  No profile is the access a session always had.  Every
  change goes through `session/set-ext` with a hint in the transcript
  ("Access: … (given up by the agent | set by the user)") and emits
  `access/changed SESSION-ID`.
- It is held by the harness, not a prompt: the `permission/dir-entries`
  filter (50) takes the dropped directories out and adds the read-only
  ones (see perms); the `agent/tools` filter (85) takes off the tools
  turned off and, without the network, those of kind net, `ssh` and
  `emacs_eval`, and `bash` and `elisp` unless `sandbox/confined-p`
  (the `tools/sandbox-options` filter, 80, then runs them with `:network
  nil`); a read-only profile is a `harness-readonly-register` policy
  (`access`), the reading tools and bash read-only and offline.  The
  gate at 4 refuses for good a call to a tool the profile takes away,
  whatever the tool list the model still has, and fails closed.
  `drop_access` stays in every tool list, read-only sessions' included
  (`harness-readonly-always-tools`).  The capabilities go to the jail:
  the same `tools/sandbox-options` filter (80) adds `:capabilities`
  (the `:caps`) to the options of the session's bash and elisp
  commands, and only when it holds some and its profile does not make
  it read-only -- never an empty key, which would make a command in a
  remote directory refuse to run unconfined -- and the readonly module's
  filter (90) takes `:capabilities` off the options of a read-only
  session's commands, whoever put it there.  Enforcing them is the
  sandbox's (see sandbox); when this filter fails the commands run
  offline and with none.
- `request_escalation` (`attribute` one of directory, read_directory,
  writes, network, tool, permission_mode, non_interactive, capability;
  `value`; `reason`) asks the user for more.  Its stage at 5 makes every
  decision final, so no mode, rule or judge sees it: a directory goes
  through the prompt of `request_directory_access`
  (`harness-perms-decide-dir-request`), the rest through
  `harness-perms-confirm` (allow-once, deny-once, in every mode, yolo
  included; a non-interactive session is refused at once).  Nothing to
  grant -- the directory reachable already, a mode no higher than the
  session's -- is allowed at once and says so; what a policy pins (the
  mode, non-interactive mode) or a deny rule covers is refused.  The
  handler grants what the user allowed.
- The attribute `capability` (`value` a capability's name, in any
  spelling `sandbox/capability-name` knows) is checked first
  (`harness-access--capability-check`), and refused at once, with a
  hint, when: there is no value; no capability has that name; the user
  does not let agents ask for it (`sandbox/capabilities` `:grantable`,
  see sandbox; the hint lists what they may); the jail does not enforce
  capabilities for the session's directory (`:enforced` nil, and its
  `:why` -- bwrap is not the backend, the directory is remote, the
  sandbox policy is `off`, bwrap is setuid or run by root -- or the
  sandbox module is not loaded, which counts as not enforced); the
  session is read-only by its own profile (it must ask for writing
  first) or by another module's policy (`harness-access--other-read-only`,
  which no escalation changes).  A session that holds the capability
  already is allowed at once and granted nothing.  Otherwise the user is
  asked through `harness-access--confirm`, as for the other attributes:
  "Give the agent's commands CAP_SYS_PTRACE", the reason saying what the
  capability lets a command do (the registry's doc), that the commands
  run in the bwrap sandbox, which drops every capability, that this one
  is valid inside the sandbox's own namespaces only (not on the host, not
  on another machine), any scope note of its own, and that it applies
  from the next bash or elisp command on, until the agent or the user
  takes it away, then the agent's own reason.  The handler gives it with
  `harness-access-grant-capability`, which makes the same checks again
  and signals a `harness-error` saying why when one fails, so a request
  the user approved by hand after a refusal (`rerun_approved`) grants
  nothing the jail or the list would not.  The result tells the agent
  that from the next command on its commands run with the capabilities
  the session holds and no other, and that commands already running
  keep what they started with.
- `drop_access` (`attribute`, `value`, `keep_read` for a directory,
  `reason`) gives access up and is allowed by the gate at 4, final, in
  every mode and session.  A directory granted to the session or the
  turn is revoked (and granted again read-only with `keep_read`); one
  of the other sources is added to `:dropped` (and `:read-dirs`).  The
  tool output directory cannot be given up, nor a directory inside
  another entry (the result says which).  A permission mode is
  dropped only to a less permissive one, and non-interactive mode only
  turned off.  With `capability` the `value` is a capability's name
  (any spelling) or `all`: the name is taken out of `:caps`
  (`harness-access-revoke-capability`).  Nothing asks anyone, the jail
  included, so it works in a read-only session and where the jail
  cannot enforce capabilities; a capability not held is nothing to give
  up, and the result says what is held.
- A write to `.dir-locals.el` or `.dir-locals-2.el`
  (`harness-access-settings-files`), which sets the harness's own
  settings for a project, asks the user at the gate through
  `harness-perms-confirm`, in every mode: a file tool's target, or a
  shell command that names one and looks like it writes it (a reading
  of its text, not a boundary).
- A session created with a `:parent-id` other than a BTW (a sub-agent,
  a fork) takes its parent's network, writing, tools
  off and dropped directories; a fork its read-only directories and its
  `:caps` too, as `session/fork` copies the parent's directory grants,
  permission mode and non-interactive state.  A fork is a session with a
  `:fork-node`: one made by `session/fork`, which `spawn_agent` with
  `fork` uses too.  A sub-agent that starts afresh and a BTW get no
  capability: they ask.  Task sessions have no parent and keep their own
  access.
- Judgements: every `permission/decided` is recorded per session in
  memory (`harness-access--judged`, the newest 300) as `(:call-id :tool
  :behavior :by :reason :hint :at)` and emitted as `access/judged
  SESSION-ID RECORD`; a `tools/result` filter (95) writes `(:behavior
  :by :reason)` into the result node's `:meta` `:judgement`, so the
  transcript keeps it across a restart.
- `access/describe SESSION-ID` → `(:session :sandbox (:backend
  :available :policy :confined :remote :module) :mode :mode-pinned
  :non-interactive :non-interactive-pinned :network :corporate
  :read-only :read-only-profile :read-only-by :profile :capabilities
  (:held :grantable :docs :enforced :backend :why) :dirs :inspect
  :skills :tools (:on :off :builtin) :never-ask :rules (:session :always
  :pinned))`.  `:capabilities` says what the session's commands hold
  (`:held`, canonical names), which an agent may ask for (`:grantable`,
  with `:docs`, a list of `(:name :doc :scope)` plists, `:scope` the
  capability's own scope note, nil for most), whether the jail enforces
  capabilities for the session's directory (`:enforced`, with the
  `:backend`) and `:why`, nil when one can be raised now, else why not:
  the jail's reason, a read-only session, or nothing grantable.
  `:dirs` are `permission/dirs` entries with `:read-only`,
  `:given-up` on a read-only entry whose directory was given up, and
  `(:dir :source dropped :dropped t)` for the rest given up; `:off`
  entries are `(:name :why :profile :elsewhere)`, `:elsewhere` for a
  tool of other kinds of session (a task's `hand_in`), which nobody
  turned off.
- `access/judgements SESSION-ID &rest FILTER` (`:behavior` allow, deny,
  ask or asked -- the ones the user answered --, `:by`, `:tool`,
  `:query` over the tool, reason, handle and title, `:limit`, default
  200, at most 1000) → `(:items :total :counts (:allow :deny :ask)
  :tools :by)`, newest first, each item `(:call-id :tool :subject :at
  :behavior :by :reason :pending-id :approved :used :call NODE :result
  NODE)`; a call waiting for the user is an `ask` item with its
  `:pending-id`.
- `access/set-network SESSION-ID ON`, `access/set-read-only SESSION-ID
  ON`, `access/set-tool SESSION-ID TOOL ON`, `access/set-capability
  SESSION-ID NAME ON`, `access/add-read-dir SESSION-ID DIR`,
  `access/remove-read-dir SESSION-ID DIR`,
  `access/drop-dir SESSION-ID DIR &optional KEEP-READ` and
  `access/restore-dir SESSION-ID DIR` change the profile for the user,
  asking nothing.  `access/set-capability` gives the session's commands
  the capability NAME, or takes it away (`all`: every one); giving one
  makes the checks a request does -- the jail enforces it, the user lets
  agents ask for it, the session may write -- and signals a
  `harness-error` saying why when one fails, so the profile never holds
  a capability the sandbox would not pass on.

### decisions

Lasting decisions: answers that hold beyond their moment, kept with
their undo and redo, the harness's rather than a session's, so any
session can move one.  A lasting permission answer (kind `permission`,
see perms), an "always" answer to the cold-cache question (kind
`cowboy`) and the switch of compacting a conversation just before its
prompt cache lapses (kind `precompact`, see cache-compact) are
decisions.

- A decision is `(:id "d-…" :kind KIND :text TEXT :record RECORD
  :session SID :node NODE-ID :at FLOAT :state STATE :result TEXT
  :moved-at FLOAT)`: TEXT what it does, as its note reads ("Always
  allowing every bash call, in every session"); RECORD what its kind
  needs to undo and redo it; SID and NODE-ID the note where it was made
  (see Node); `:result` how its last move went, in a sentence.
- STATE (`harness-decision-states`) is a cursor: `done` while what it
  changed is in effect, `undone` once taken back; `changed` (what it
  changed was changed since, by Settings or another answer) and `gone`
  (it is no longer there) end it.  Undo moves `done` to `undone`, redo
  back, each only while the setting holds what the other move left:
  a move never takes back a change somebody else made, and of two
  decisions about one setting only the one that holds it moves.
- `harness-decisions-define-kind KIND :undo FN :redo FN`: the module
  that owns the setting defines its kind as it loads.  Each FN takes
  the decision and returns `(OUTCOME . MESSAGE)`: `undone`, `done`,
  `changed` or `gone`, and the sentence (nil for the default one).  A FN
  that signals, or a kind no module defines, moves nothing: the outcome
  is `failed` and the decision stays as it was.
- `decision/record KIND SESSION-ID TEXT RECORD &rest OPTS` → the
  decision, `done` (OPTS: `:node`, `:at`, and `:state` with `:result` for
  one taken in after the fact).  `decision/attach ID SESSION-ID NODE-ID`
  names its note.  `decision/get ID`, `decision/list &rest OPTS`
  (`:kind`, `:state`, `:session`, `:limit`; newest first).
- `decision/undo ID`, `decision/redo ID` → `(:outcome OUTCOME :message
  TEXT :decision DECISION)`, OUTCOME the state after it or `failed`.  A
  decision in no state to move returns its state and why, unchanged.
- Event `decision/changed DECISION` on every decision kept, attached
  or moved; ACP forwards it, and clients call the methods as
  `_harness/decision/…`.
- The newest `harness-decisions-kept` (500) are kept in the store
  (`decisions.json`), so the notes' buttons work after a restart.

### sandbox

- `sandbox/wrap CWD COMMAND-LIST &optional (:network t :writable (…) :readable (…) :read-only nil :scratch (…) :capabilities (…))` →
  command list (bwrap / systemd-run / mxc-exec-mac / plain).
  `sandbox/status` → `(:backend bwrap|systemd|mxc|none :available (…)
  :policy …)`.  `harness-sandbox-detect` looks for bwrap and
  systemd-run on GNU/Linux and for `harness-sandbox-mxc-program` on
  macOS only; a backend forced off its platform is `none`.  Fails closed
  when `harness-sandbox-policy` is `required` and no backend exists.
  A confined command has `HARNESS_SANDBOX` set to the backend's name,
  `bwrap`, `systemd` or `mxc`, so a script can tell it runs confined
  (`scripts/dev.sh start` warns that an Emacs it starts there ends with
  the command).
  Without the sandbox module the bash and elisp tools fail closed for
  `required` too (`harness-tools-shell--wrap`), rather than running the command
  unconfined.
- `:read-only`, for a caller that needs a command to change nothing (a
  supervising session's shell, which only looks), mounts the working
  directory, the git directories and every `:writable` entry read-only
  as well, so the command writes nothing but the sandbox's private
  /tmp (its private `$TMPDIR` under MXC).  It fails closed whatever the
  policy: where the command would run unconfined, with the `off`
  policy, in a remote CWD or with no backend, `sandbox/wrap` signals
  `harness-sandbox-unavailable` instead of returning COMMAND.
  `sandbox/confined-p CWD` says beforehand whether it can be had.
- `:capabilities` names the Linux capabilities the command is given
  (`(:capabilities ("CAP_SYS_PTRACE"))`), none by default: bwrap drops
  every one.  Run by an ordinary user, bwrap makes a user namespace of
  its own, and `--cap-add NAME` keeps NAME there: a capability of that
  namespace, which counts for the sandbox's processes, mounts, IPC
  objects and hostname and, with `:network nil`, for its network
  namespace -- and for nothing the host owns: with the network on the
  sandbox shares the host's network namespace, so the `CAP_NET_*` change
  nothing there, and no capability reaches a command on another
  machine, which the sandbox does not run.  `sandbox/wrap` applies these
  rules, in this order:
  - `:read-only` wins: a command that changes nothing is given none,
    whatever is asked, and no capability can make it fail.
  - A command that runs unconfined anyway -- the `off` policy, a remote
    CWD, no backend where the policy allows it -- has its user's own
    rights and comes back as it is, with a line in the debug log.
  - bwrap: each name must be in the registry and listed in
    `harness-sandbox-grantable-capabilities` when the command is
    wrapped.  One that is not is left out with a line in the log, so a
    capability held and no longer grantable is silently not passed on:
    the command runs with fewer.  Each name left becomes one `--cap-add
    NAME`, once, in the order asked, after `--new-session` and before
    `--chdir`.  `harness-sandbox--bwrap-command` is the last guard of its
    command line: it passes only registry names, and none with
    `:read-only`.  When there is a name to pass and `--cap-add` would
    be no capability of the sandbox's own namespace, `sandbox/wrap`
    signals `harness-sandbox-unavailable`: the executable is setuid
    (`file-modes` has the setuid bit: an old bwrap installed setuid
    root, where `--cap-add` hands out real capabilities of the host), or
    Emacs runs as root (bwrap then makes no user namespace unless asked
    and starts from all the capabilities of its caller, which every
    command keeps, so nothing is dropped to raise or lower and
    `--cap-add` would be real).  Those two cases are refused rather
    than made uniform with `--unshare-user`, which has not been verified
    for a setuid bwrap.
  - systemd-run (a `--user` unit can only lower its own capabilities)
    and MXC (Seatbelt has none) signal `harness-sandbox-unavailable`
    for any `:capabilities`, before MXC makes the command's private
    `$TMPDIR`: the command does not run without what was asked for.
    Each refusal says why and points to `drop_access` (attribute
    capability, value all), which lets the session's commands run again.
- The registry `harness-sandbox-capabilities` lists the 41 Linux
  capabilities the harness knows, the kernel's, each `(NAME :bit BIT
  :doc DOC [:scope SCOPE])`: NAME the canonical name (`CAP_SYS_PTRACE`),
  BIT its number in the kernel's capability sets (the bit `CapEff` in
  /proc/PID/status shows; `harness-sandbox-capability-mask` gives the
  mask of some names), DOC one line of what it lets a command do, and
  SCOPE, when there is more to say than that every capability counts
  inside the sandbox's own namespaces only: the network ones count only
  without the network, `CAP_SYS_PTRACE` reaches the PID namespace of the
  sandbox, `CAP_SYS_ADMIN` can undo the read-only mounts.  It is the
  injection guard of bwrap's argument vector: only a name in it ever
  reaches the command line, and `ALL` is not in it.
  `harness-sandbox-capability-name VALUE` (method
  `sandbox/capability-name`) gives the canonical name of a string or a
  symbol, or nil: case, dashes and spaces do not matter, the `CAP_`
  prefix is optional, and a name may leave out `SYS_`, so
  `CAP_SYS_PTRACE`, `SYS_PTRACE`, `sys_ptrace`, `cap-sys-ptrace` and
  `ptrace` are one; anything else is nil, `ALL` and what holds more than
  a name included.
- `harness-sandbox-grantable-capabilities` lists the names an agent may
  ask for.  It is a plain option of the `harness` group (advanced on the
  settings page) of the user, or of an administrator's policy -- not a
  layered key, so a project's `.dir-locals.el` cannot widen what the
  agents jailed in it may ask for: the harness reads its default value
  only (`harness-sandbox-grantable`), never a buffer-local one, and the
  option is `:risky`.  Its entries are read in any spelling; one that is
  no capability is reported once and skipped.  The default is
  conservative: `CAP_SYS_PTRACE` (trace and inspect any process of the
  sandbox, and lift Yama's descendants-only rule), `CAP_NET_RAW`,
  `CAP_NET_ADMIN` and `CAP_NET_BIND_SERVICE`, the last three effective
  only for a session without the network, in the sandbox's own empty
  network namespace.  `CAP_SYS_ADMIN` is left out on purpose: it lets a
  command mount, remount and join namespaces inside the sandbox, which
  can undo the read-only mounts the jail relies on (a read-only
  session's, the protected git hooks and config of a worktree, the
  skills directories); a user can add it, or any capability of the
  registry, at their own risk.  `ALL` is never grantable.  Nil switches
  the feature off, a corporate policy's way: nothing can be asked for,
  and one held is no longer passed on.
- `sandbox/capabilities CWD` → `(:enforced BOOL :backend SYM :grantable
  (NAME…) :docs ((NAME . DOC)…) :scopes ((NAME . SCOPE)…) :why TEXT)`:
  what the jail does for commands run in CWD.  `:enforced` is non-nil
  only when the backend is bwrap, CWD is local, the sandbox policy is
  not `off`, and `--cap-add` is a capability of the sandbox's own
  namespace (bwrap neither setuid nor run by root); `:why` says what
  stands in the way when it is not.  `:grantable` are the canonical names
  of the option that are capabilities the harness knows, `:docs` one
  line for each, `:scopes` the scope notes of those that have one.
  Nothing grantable still enforces: nothing can be asked for.  Whether a
  session may be given one is for the access module, which treats a
  missing sandbox module as not enforced.
- `:scratch` lists directories the caller made for the one command and
  deletes after it, which the command writes even when it is
  `:read-only`: the elisp tool's background Emacs leaves its result in
  one.  They are mounted after everything else (bwrap `--bind`;
  systemd `BindPaths=` and `ReadWritePaths=`), so nothing covers them.
  One that is no local directory, or is `/`, holds the working
  directory or the home directory, or is, holds or lies in `/usr`,
  `/etc`, `/proc`, `/dev` or `/sys`, signals an error
  (`harness-sandbox--scratch-mounts`): shown writable, it would undo
  what the sandbox hides or keeps read-only.  They ask for no
  confinement: where the command runs unconfined it reaches them
  anyway.
- `$HOME`: bwrap keeps its path, covered by an empty tmpfs (after the
  one on /tmp, which may hold it, and before every bind), so `~/x`
  names the same path inside as outside and shows only what is mounted
  there; the credentials in the rest of the home directory stay out of
  reach, and nothing written there outside a mount survives the
  command.  A `$HOME` that is unset, relative, remote, `/`, or is,
  holds or lies in a directory the sandbox mounts its own (`/usr`,
  `/etc`, `/proc`, `/dev`, `/sys`; `harness-sandbox--real-home`) gives
  way to `/tmp/harness-home` (`harness-sandbox--home`, set as `$HOME`).
  systemd-run hides the home directories with a read-only tmpfs and
  sets `$HOME` to its private /tmp.  A home directory inside CWD shows
  as it is.  It used to be `/tmp/harness-home` always, so `~` in a
  command named another place than in every other tool.
- The bash tool passes the directories the session may use
  (`permission/dirs`: its cwd, worktree, temporary directory
  (`session/tmp-dir`, also asked for directly), the configured
  `harness-allowed-directories`, its grants to the session and until
  its turn ends) as `:writable`, and the tool output directory as
  `:readable`, read on every call so a grant reaches the next command;
  no session, a remote cwd or a command for a host passes none.  They
  used to reach every tool but bash, which saw only its cwd, so a user
  granting a directory saw the agent's commands fail there and was
  asked again.  The temporary directory is bound at its real path,
  after the private tmpfs on /tmp, so a command can leave files there
  for the next command and the other tools, while the rest of /tmp
  stays private to each command.
- The bash tool passes the skills directories every read may read (the
  `:contained` ones of `skills/directories`) as `:readable`, so `cat
  ~/.claude/skills/x/SKILL.md` works in the sandbox as outside it.
- `harness-sandbox--mounts READABLE WRITABLE CWD HOME` → `(MODE SOURCE
  DEST)` mounts, `ro` for a readable directory or file and `rw` for a
  writable one, each shown where it is named, where its symbolic
  links lead, and, under a `$HOME` that is not the real one's path
  (HOME: `/tmp` for systemd-run, `/tmp/harness-home` when bwrap cannot
  keep the path), at the same place under it.  Left out: what lies
  inside CWD (shown read-write anyway), `/` (it would cover the
  sandbox's own /proc, /dev and /tmp), a readable directory that is or
  holds the home directory (a writable one was granted, so it shows), a
  destination below another one it shows through as it is (below a
  writable one, or a readable one below a readable one; bwrap refuses
  to mount on the symbolic link it may be there: a skill linked into
  `~/.claude/skills`), and one holding a CWD named through a link.  A
  destination named both ways is writable.  A writable one below a
  readable one stays when it is its own real path, and is mounted after
  it, so a grant inside a skills directory is writable.  bwrap gets the
  read-only binds first, then the writable ones, then CWD's, since a
  later bind covers what an earlier one shows below it, so a CWD inside
  a skills directory stays writable; systemd-run orders its mounts
  itself (`BindPaths=` / `BindReadOnlyPaths=SRC[:DEST]`) and leaves
  out a path its setting cannot hold as written (whitespace, colons,
  quotes).  `harness-sandbox--readable-mounts` gives the readable ones
  alone.  Only these directories become visible: the rest of the home
  directory stays hidden.  `sandbox/confined-p CWD` says whether commands run in
  CWD are confined (a backend, a policy other than `off`, a local CWD);
  the perms module refuses a command naming a skills path the sandbox
  does not show.
- A CWD inside a linked git worktree also gets the repository's common
  git directory read-write (its `hooks/` and `config` stay read-only, so
  nothing planted there runs when the harness uses git unconfined; the
  main checkout's `index` and `HEAD` stay read-only too, since git there
  would see the main checkout's files, absent from the sandbox, as
  deleted and could wreck its index) and
  the host's `user.name`/`user.email` as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`,
  so worktree sessions can commit.
- Git in the sandbox sees no other worktree's files, so it takes every
  other worktree for deleted.  `sandbox/check-command CWD COMMAND
  &optional OWN` gives nil or `(:reason :hint)`: why a shell command must
  not run confined in CWD.  It refuses `git worktree prune`, and `git
  worktree unlock|remove|move` of a worktree that is outside OWN (the
  session's own worktree, by default the one holding CWD), is OWN itself,
  is locked by the harness (reason `harness: ...`), or cannot be told
  (variables, globs, `xargs`).  It reads the command line as the shell
  does, closely enough: quotes, operators and redirections, `$(...)` and
  backticks, `sh -c` and `eval` scripts, wrappers (env, timeout, xargs,
  find...), `cd`, git's global options (`-C`, `-c alias.NAME=...`), and
  worktrees named by the end of their path, as git allows; a `cd` in a
  subshell or a pipe does not carry on.  Shell variables, scripts run
  from files and aliases from git's config are not resolved: the locks
  protect the harness's worktrees from those.  The reason points to
  `worktree/prune` and `worktree/remove`, which run outside the sandbox.
  Commands that run unconfined (no backend, policy `off`, remote CWD)
  are never refused.  The perms module's sandbox guard calls it.
- MXC, on macOS (`harness-sandbox--mxc-command`): the wrapped command
  is `PROGRAM --config-base64 B64`, the whole command as JSON (version
  1.0.0, containment `seatbelt`, `nestedPty`, no MXC timeout), which
  `mxc-exec-mac` runs as `/bin/sh -c` in CWD.  Seatbelt confines by
  path rather than by mounts, so the same directories go as an
  allowlist at their real paths: read-write CWD, the `rw` sources of
  `harness-sandbox--mounts` and a worktree's common git directory;
  read-only its `ro` sources, the toolchain directories that exist
  (`harness-sandbox--mxc-system-dirs`: Homebrew, /usr/local, MacPorts,
  Nix, /Applications) and `harness-sandbox-extra-read-only-dirs`, each
  unless a writable one holds it, and the protected git paths, which
  stay read-only inside the writable git directory (the deepest rule
  wins).  MXC's own baseline gives the system (/bin, /usr, /System,
  /Library, /private/etc…).  `sandbox/wrap` makes a private 0700
  directory the command's `$TMPDIR`, writable, and the command line
  removes it after the command, keeping its status (a command killed by
  a signal leaves it for macOS to clear).  MXC passes no environment on:
  the command gets `process-environment` (the first entry of a name
  wins, a bare name unsets it, an entry JSON cannot carry is left out)
  with `TMPDIR`, `PWD`, `HARNESS_SANDBOX=mxc` and the git identity set;
  `$HOME` keeps its path, unreadable but for what is shown.  The network
  is allowed all ways (egress, ingress and host loopback, which MXC
  takes only with ingress) or denied all ways.  `:read-only` leaves
  only `$TMPDIR` writable and shows CWD, the writable directories and
  the common git directory read-only.  Unlike bwrap the command gets no
  PID namespace (only a session of its own), `/tmp` cannot be written,
  and MXC hands the output over only when the command exits, so the
  bash tool's live note shows nothing until then.  MXC needs macOS 15
  or later.

### agent

- `harness-agent-step-request SESSION-ID STATE ON-EVENT` (a function,
  not a method: its result holds closures and the whole conversation) →
  the request the next step of the session sends: `(:model :session
  :system :messages :tools :builtin-tools :thinking :provider-state
  :on-event)`, STATE the provider state the step carries.  The one place
  a step's request is made: the turn calls it for every step, and what
  has to send something that starts like a step does too -- a provider's
  prompt cache reads a request only as far as it starts like the one that
  wrote it (see cache-warm).  Making one changes nothing.
  `harness-agent-last-request SESSION-ID` is the request of the latest
  step of the session's running turn, without its `:on-event`, nil when
  no turn runs: the step after a tool call starts as it ended, so sending
  it again reads the cache it wrote.
- `agent/prompt SESSION-ID BLOCKS &optional OPTS` → promise of
  `(:stop-reason …)`.  Idle session: starts a turn.  Running session:
  steering — the message is queued and injected at the next step boundary
  (appended to the next tool result, a hosted loop handed its images
  with that result, or sent as the next user turn if the model stops
  first), and only once.  OPTS `:queue` true only
  queues, even while a turn runs.  OPTS `:from`, when the user is not
  the sender, is the sender plist (see "Node") kept on the message's
  node (and on a queued item).  An empty message is refused, and so is
  any message to an internal session (`session/internal-start`): it
  records one model call and cannot be continued.  An
  inactive session is resumed first (`session/resume`), so a message
  sent to a closed session brings it back; queueing leaves it closed.
- `agent/cancel SESSION-ID`.  Emits `agent/cancelling SID` at once, so
  that a gate holding the turn before it starts (the cowboy module's
  question) lets it go: the turn then ends `cancelled` as soon as its
  `agent/before-turn` chain settles, with no "Turn not started" hint,
  rather than after the grace period of a provider's cancel.
- `agent/note-activity SESSION-ID ACTIVITY` — announces ACTIVITY (an
  `agent/activity` value, `(:phase compacting)` say) for a turn still
  held by its gate: the cowboy module's compaction before the message.
  The turn sets its own when it starts and clears it when it ends.
- `agent/send-queue SESSION-ID &optional QIDS` — sends the queued items
  as one turn: every item, or with QIDS (a list of item ids) only
  those, which sends one message now and leaves the others queued for
  the turn that sends the queue (a QIDS naming nothing queued any more
  starts nothing: `(:stop-reason nothing-queued)`).  While a turn runs
  the items steer it, like any message sent then.  The message is the
  user's when any item is, else from the first item's sender.  An
  attachment of an item that carries its own `:text` and no `:path` -- a
  task, say -- goes to the model as that text
  (`harness-attachments-to-blocks`).
- `agent/withdraw SESSION-ID NODE-ID` — takes back a steering message
  the running turn has not delivered yet: it leaves what the turn will
  deliver and the transcript (`session/discard-nodes`, announced as
  `session/nodes-removed`), so the model never gets it, and the node is
  returned.  It signals when the turn does not hold the message (it was
  delivered at a step boundary meanwhile, the turn is over, or the node
  is no steering message of the session) and then changes nothing.  The
  chat's [delete] and [edit] on a queued message call it.
- Sync filter `agent/message` (value the message's blocks; args SID
  and `(:from FROM :steering BOOL)`) on every message as it is
  delivered: when it starts a turn or steers one, a queued message when
  its queue goes out, never while it waits there.  What it returns is
  the message (nil leaves it as it was); the tasks module sends a task
  waiting for review back this way when the user wrote the message,
  and opens another session's with a note that it is no review.
- Async filter `agent/stop` (value `(:stop t)`, args the session plist),
  asked when the model stopped on its own (`end-turn`) with no steering
  waiting and the turn not cancelled.  A handler that answers `(:stop nil
  :message TEXT :from SENDER)` sends the model on: TEXT is recorded as a
  message of the harness's (`(harness-sender-system "harness")`, or
  `:from` when that names a sender), marked as steering like a message
  sent mid-turn, and the turn takes one more step, which delivers it
  (asked of `agent/step`, as any step is).  At most
  `harness-agent--max-stop-continues` (3) times a turn; the filter is
  not asked after that.  Any other answer ends the turn `end-turn`, and
  with no handler on the filter it ends at once, without asking, as it
  did before the filter existed.  A handler that fails is logged and
  leaves the answer as it was, and a message sent to the turn meanwhile
  gets its step even when the answer is to stop.  The supervisor
  module's stop rule is such a handler.
- `agent/outstanding SESSION-ID` → a short text, or nil: what runs for
  the session outside its own turn, such as a supervisor plan's workers.
  A module that started work which goes on without the turn reports it
  to the sync filter `agent/outstanding`, whose value starts at nil and
  whose argument is SESSION-ID.  A handler with nothing to report
  returns the value unchanged; one that reports returns its own text, or
  appends it to the text before it, separated by "; ".  A value that is
  not a text with words in it counts as nothing outstanding.  The tasks
  module keeps the task of a session whose turn ended active while this
  says something (see tasks).
- `agent/stop-outstanding SESSION-ID &optional REASON` → a short text, or
  nil: stops what runs for the session outside its own turn, the
  counterpart of `agent/outstanding`, and says what it stopped.  A module
  that started that work stops it when asked through the sync filter
  `agent/stop-outstanding`, whose value starts at nil and whose arguments
  are SESSION-ID and REASON: a short text saying why ("its task was
  returned to the queue"), or nil.  A handler records REASON where the
  owner of the work reads it, such as a supervisor step's `:error`, and
  has nothing to do (returns the value unchanged) when it started
  nothing for the session; one that stopped something returns a text
  saying what, or appends it to the text before it, separated by "; ".
  Registrations that only wait, those of `session_wait`, are left alone.
  A value that is not a text with words in it counts as nothing stopped.
  The tasks module calls it when a task is pre-empted or returned to
  pending, once no turn of the task's session runs, so that the reports
  of the stopped work reach a session with no turn to steer (see tasks).
  The handlers are the supervisor module's, which interrupts the running
  steps of the session's plans, and tools-agent's, which cancels the
  sub-agents the session spawned (see supervisor and tools).
- Sync filter `agent/system-prompt` (value string, args session); sync
  filter `agent/tools`; sync filter `agent/builtin-tools` (see
  `tools/builtin`); async filter `agent/before-turn` (value
  `(:proceed t :reason :message (:text TEXT :from FROM))`, args session)
  — budgets, merge holds, the cold-cache question (cowboy, 15) and
  compaction (20) hook in here.  `:message` is the message the turn
  starts with, not yet in the transcript: the turn appends it once the
  chain settles, so whatever a gate appends (a compaction) comes before
  it.  A turn cancelled while the chain held it does not start;
  `:proceed` nil ends it `blocked`, with the hint "Turn not started:
  REASON"; async filter `agent/step` at every step
  boundary (same value shape) — merge holds pause here; async filter
  `agent/step-error` when a provider request fails (value `(:retry
  nil)`, args session and FAILURE `(:error TEXT :error-kind KIND
  :resets FLOAT :model MODEL-ID :step N)`, the `done` event's keys plus
  the model the step ran on) — a handler that returns `(:retry t)`
  has the step run again, on the session's model as it is then: the
  fallback module switches the model and retries, and the retry module
  tries the same model again after a transient failure.  Before the
  step runs again, the partial answer it had streamed is dropped
  (`harness-agent--rewind-step`, `session/discard-nodes'): neither the
  transcript nor the model is sent the same tokens twice.  Nothing is
  dropped for a hosted-loop provider, whose own conversation cannot be
  rewound.  A turn retries at most
  `harness-agent--max-error-retries` (8) times; otherwise, and
  without a handler, the turn ends with `error` as before.
- Events `agent/turn-started SID`, `agent/turn-ended SID REASON`,
  `agent/cancelling SID`,
  `agent/stream SID NODE-ID KIND DELTA` (kind text|thinking),
  `agent/tool-call SID NODE`, `agent/tool-result SID NODE`,
  `agent/activity-changed SID ACTIVITY`.
- The system prompt's Environment section names the working directory,
  the session's own temporary directory (asked for with
  `session/tmp-dir` at every step, so it exists whenever the model is
  told about it; the line is left out when there is none), the project,
  the date, the system and the Emacs version.
- Turn loop: build system prompt → messages → `provider/complete`;
  stream deltas into a live assistant/thinking node (created on the
  first delta with visible text: whitespace before it is held back and
  opens the node with that text, so a stray newline never makes an empty
  message; updated in place); on `tool-call` append a tool-call node, run
  `tools/execute`, append the tool-result node; native loops re-call the
  provider until `end-turn`; hosted loops respond through `:respond`.
  Steering is drained at every boundary (each tool result and each
  step), so it is delivered once; a model that stops with steering
  waiting gets one more step with it as the newest user message.
  Taking steering marks each of its nodes `:delivered-after` the newest
  node that is not steering, whether the model's place for the message
  moves (`session/messages`) or not, which is how a UI tells a message
  the model has from one that still waits for its next step.  Until
  then the user can take a message back (`agent/withdraw`).
  A turn has no step limit: long unattended work is the point, and the
  loop ends when the model stops, the provider errors or hits its
  output limit, the user cancels, or an `agent/step` filter (a merge
  hold) pauses it at a boundary.  Automatic compaction runs between
  turns (`agent/before-turn'), not inside one, so a native-provider
  turn that outgrows the window reaches the provider's own error;
  a hard budget spent mid-turn ends the turn at the next step boundary
  (see "usage" below), and one already spent refuses a new turn.
- Images a tool returns for the model (`:images` of its result, see
  tools; read_file on an image gives them) are the model's to see only
  when it reads images (its `:input-modalities` list "image",
  `harness-agent--vision-p`); a model that does not is told in the
  result's text that only the user sees the image
  (`harness-agent--no-vision-note`).  The result node keeps the files'
  paths and types, never their bytes, and only a path of an
  `image/png`, `image/jpeg`, `image/gif` or `image/webp` file, from a
  call that did not fail.  A hosted loop is handed them with the result:
  `:respond` gets `(:content TEXT :is-error BOOL :images IMAGES)`, each
  of IMAGES `(:mime MIME :data BASE64 :name FILENAME)`, read when the
  call ends and only then; a file that cannot be read is left out and
  the text says it is gone.  The note, like that one, comes before the
  steering the result carries.  A native loop is sent them with its next
  request: `harness-agent--prepare-messages` makes each tool_result
  block's `:images` image blocks with `:data`, or drops them with the
  note, and nothing is read for the call itself.  A request carries
  only the newest `harness-agent-history-images` (16) images of tool
  results: a native provider is sent the whole conversation again at
  every step, so past that the oldest go in chunks of half as many,
  counted from the conversation alone, so the request is the same from
  step to step between two chunks and the provider's prompt cache
  lasts; the result of a call whose image went says it is no longer
  attached, and the model can read the file again.  A hosted loop is
  sent none from the transcript, having been handed each once; neither
  are a summary or a title (compaction and naming), which are written
  from words (`harness-agent-strip-result-images`).
- Images a steering message holds (attached in the box while the turn
  runs, or to an answer, see `question/answer`) reach the model as
  those of a message sent first would.  A native loop gets the message,
  images and all, in its next request, each image after its token.  A
  hosted loop hears steering only as text inside the next tool result
  (`<user_message>…</user_message>`, `harness-agent--with-steering`), so
  it is handed the message's images with that result, after the
  result's own: each of IMAGES then carries the `:label` its token in
  the text names (image 1 for `[image 1]`), which Claude Code sends as
  a text block of the token right before the image and Copilot names
  the image's blob after (`harness-agent--hosted-steering-images`).  A
  model that does not read images is told that only the user sees them,
  and an image that cannot go (its file gone, a type no provider takes)
  is named in the text with why.  A call that failed hands no images,
  so a message with images waits for the next result, or for the next
  user turn.
- Each step reads the session's model afresh: a model switch reaches a
  running turn at its next step, never mid-step.  The step sends only
  the provider state its model can continue and drops one of another
  provider (see "provider", Provider state); what the step writes (the
  `:meta` `:model` of its nodes, the provider state it reports) is the
  step's model's.
- Every node a model produces (assistant, thinking, tool-call) records
  that model in `:meta :model`.
- Handoff to a hosted loop: a hosted provider only gets the trailing
  user message, its own conversation being the rest.  When the
  transcript holds output of another provider's model after this
  provider's last (a fallback, or a model switched by hand), what that
  conversation missed -- from there, or from the last compaction --
  is rendered as text at the head of the trailing user message:
  messages, tool calls and results, each cut to
  `harness-agent--handoff-item-chars`, the oldest left out beyond
  `harness-agent--handoff-max-chars`; thinking is left out.  A request
  that ends in tool results (a step retried mid-turn) closes the text
  by asking the model to carry on, since a hosted provider drops tool
  results it did not ask for.
- Streaming updates of the live node are not persisted one by one; on
  exit (`kill-emacs-hook`) and shutdown the text streamed so far is.
- Provider conversation and head: before a turn's gate,
  `harness-agent--follow-head` asks `session/provider-continuation`.
  When the head moved off the provider conversation, it stores the
  provider's fork cut at the last checkpoint on the head's path
  (`provider/fork` with that checkpoint), or no state, and the head as
  `:provider-node`.  The turn then runs on the cut conversation, or a
  new one seeded with the transcript.  Every turn's end records the
  head as `:provider-node`.  `checkpoint` events and a `tool-call`'s
  `:checkpoint` are stored on their nodes (see "provider").
- Activity: `agent/activity SID` returns what the running turn does now,
  nil when none runs: `(:phase PHASE :since FLOAT ...)`, `:since` being
  when the phase began.  PHASE is `waiting` (for the model: at every
  step and after each tool), `thinking`, `writing`, `tool-input`
  (`:tool`, `:chars`), `compacting` (from the provider's `activity`
  events and the deltas), or `tool` while calls run: the oldest is
  `:tool` with `:title`, `:checking` until its permission is decided
  (its time then starts again), `:detail` the last line of its
  `tools/progress` (at most every `harness-agent--progress-interval`,
  0.5 s), and `:count` when several run.  A `tool` phase also carries
  `:calls`, one plist per running call -- the same fields with its
  `:call-id`, and `:note`, the text of its `tools/note` -- so the chat
  puts each call's note under that call's own block.  Every change is
  announced as `agent/activity-changed`, with nil when the turn ends.
  The state lives beside the turn records, so a reload keeps it.

### usage

- Subscribes `session/usage`; records to sqlite (`usage` table:
  ts, session, project, model, input, output, cache_read, cache_write, cost,
  turn, list_cost, billing; older tables gain the last two in place).
  The harness's own model calls, recorded as internal sessions (see
  "session" and "provider"), reach it the same way: the cost of each is
  one row, under its session's project.
- `usage/budget-block SESSION-ID` → the reason a hard budget forbids another
  request in the session -- the one the `agent/before-turn` gate gives --
  or nil.  A request that is no turn, such as keeping a prompt cache warm
  (cache-warm), asks it before it spends.
- `usage/summary &key group-by since until project session model billing` → rows
  `(:key :input :output :cache-read :cache-write :cost :list-cost :calls)`;
  group-by `project|model|day|hour|session|billing` (billing keys "api",
  "subscription", "extra-usage", "" when unrecorded); sorted by list
  cost.  `:cost` is what was billed, `:list-cost` the same usage at API
  prices (rows from before list costs count their cost).  By project a
  row also has `:main`, the main checkout its project belongs to
  (`harness-project-main`, resolved here so the UI never reads the disk
  for it): a linked git worktree's, such as a task's, is its
  repository's main checkout, also once the worktree is removed or git
  pruned its registration; a scratch directory's, such as a sub-agent's
  working directory, is the project of the session whose temporary
  directory it is; any other project's is its own root, and the row
  without a project has "", as does one in a scratch directory whose
  session is gone.
- `usage/budgets`, `usage/set-budget BUDGET`, `usage/remove-budget ID`,
  `usage/budget-status ID &rest (:now)` (ID may be "session:SID" for a
  session's implicit budget) → `(:budget :spent :amount :remaining
  :fraction :hard :per-day :days-left :period-start :period-end
  :baseline :reported :sources)`;
  `usage/session-budgets SID` (every budget that applies to the
  session), `usage/project-budgets ROOT` (the project budgets of ROOT
  and the period budgets of everything or of ROOT, as statuses; what
  the task board shows), `usage/plan-budget AMOUNT PERIOD DAYS`,
  `usage/totals`, `usage/series (:bucket day|hour …)`, `usage/record ROW`,
  `usage/cost-compare (&rest usage/totals filters, :models :reference-model
  :at)` (what the recorded tokens would cost at other models' prices; see
  "Cost comparison").
  BUDGET = `(:id :scope session|project|period :target ID-OR-ROOT
  :amount F :hard BOOL :period day|week|month :days business|all
  :baseline F :baseline-period-start "YYYY-MM-DD")`.
- `:spent` is the recorded cost, plus `:reported`, plus `:baseline`.
- A budget over everything (scope period, no target, a day, week or
  month: `harness-usage-backfills-p`) backfills from what providers
  report they billed in its period.  `:reported` is the sum of each
  source's `:outside`, and `:sources` lists them as `(:source ID :label
  NAME :kind extra-usage|cost-report :amount :recorded :outside :at
  :detail TEXT)`, plus `:since :until` for a cost report.  `:amount` is
  what the source reported as of `:at`, `:recorded` what the harness
  recorded before then that the source counts too, and `:outside` the
  rest, never below 0.  Two sources:
  - Extra usage: a `provider/quota-updated` QUOTA whose `:extra :used`
    is in US dollars covers the calendar month of its `:updated` time.
    That is Claude Code's usage credits (the CLI's `get_usage`) or
    Copilot's overage.  It counts in month budgets, less that
    provider's rows billed `extra-usage`.  A QUOTA without `:extra`
    (per-token billing) drops the provider's report.
  - Anthropic's cost report (below), for the UTC days of the period's
    local dates, less the Claude rows billed per token.  It is fetched
    in the background, from the command loop, when a status is computed
    without `:now` and the last try for that period is older than
    `harness-usage-cost-report-interval` (600 s).  A failure, or a
    missing key, is remembered for as long and keeps the amount fetched
    before.
  Reports live in memory, and `usage/reported-changed REPORT` fires when
  one changes (forwarded to clients, and the dashboard reloads).
  Project, session and per-project budgets do not backfill: a provider
  cannot say what one project spent, and a session spends only through
  the harness.
- A baseline is what was spent that the harness never recorded and no
  provider reports (other tools, the console, days before it kept
  usage), set by hand so a budget made mid-month does not start at $0.
  It counts besides `:reported`: a period budget's only while the
  current period starts on `:baseline-period-start` (set-budget fills
  in the period containing now, and moves any date or float time to its
  period's start), one without a period always.  The status's
  `:baseline` is that part, 0 otherwise.  nil or 0 clears it.
- `usage/fetch-api-cost &rest (:period :now)` gives a promise of what
  Anthropic billed in the calendar `:period` (day, week or month, the
  default) containing `:now`, from its Admin API (`GET
  /v1/organizations/cost_report`, UTC days, amounts in cents):
  `(:available t :amount :recorded :outside :period :period-start
  :since :until)`.  `:recorded` is what the harness recorded in that
  time for Claude calls billed per token, which the report counts too,
  and `:outside` the rest.  The answer also updates what budgets over
  everything count, at once.  It needs an Admin API key
  (`harness-anthropic-admin-api-key`, ANTHROPIC_ADMIN_KEY, or
  auth-source host api.anthropic.com user admin); without one nothing
  is fetched and it gives `(:available nil :reason)`.  Pro and Max
  subscriptions have no cost report.
- Hard budgets stop a turn: `agent/before-turn` refuses a new one, and
  `agent/step` refuses the next step of a running one, which then ends
  `blocked` with the reason as a hint (the step in flight finishes, so a
  hosted loop's call in progress is not cut off).  Soft ones emit
  `usage/budget-warning` and a session hint at 80% and 100%.  Budgets
  count billed cost, so calls a subscription covers spend none; what
  providers report and a baseline count toward both.
- The Budget setting (`harness-budget`, `(:amount F :hard BOOL)`) is
  one implicit budget, id "settings", for all sessions together: it
  counts every recorded call and applies to every session, after the
  explicit ones in `usage/session-budgets` and `usage/project-budgets`
  (so the task board's header shows it too).  `usage/budget-status
  "settings"` gives its status while it is set; `usage/budgets` lists
  only the explicit ones.  Sessions no longer copy it into their own
  `:budget`; the session module drops the copies saved before, once
  (marker `session-budget-copies-dropped.json`).
- Pricing: `usage/price MODEL-ID USAGE` → cost using the model's pricing.
- Output rate: how fast each session's model writes, measured here in
  the harness process, never in the UI.
  - Tokens: the accounting's own counts, never a second count of the
    stream. Each `session/usage` record supplies them, and on a hosted
    loop so does each model call's `agent/call-usage` (see provider
    `call-usage`). A hosted loop's record of the turn's total is not
    measured again once its calls were.
  - Seconds: the streaming time, meaning the time the agent's activity
    (`agent/activity-changed`) is in `thinking`, `writing` or
    `tool-input`. The wait for the first token, the tools' runs and
    compaction do not count.
  - Calls: a call with no output, or with less than 0.25 s of streaming
    (output that arrived all at once), is left out; so is a
    `call-usage` that only gives a call's prompt (`:output 0`).
  - The rate: Σoutput / Σseconds over the session's newest calls on its
    current model, counting back until they cover
    `harness-usage-rate-window` seconds of streaming (30). It is kept in
    memory after the turn, so an idle session keeps its last rate, and
    is dropped when the session is deleted.
  - Interface: `usage/rate SID` returns `(:rate F :output N :seconds F
    :calls N :at FLOAT :model ID)` or nil. `usage/rates` returns every
    measured session's rate, each with `:session`. Each new rate
    triggers `usage/rate-updated SID RATE`, which ACP forwards.
  - Average over the whole session: every call measured, whatever its
    model, is also added to the session's usage totals as
    `:stream-output` and `:stream-seconds` (`session/usage-note`; a
    failure is logged and never breaks the measurement).  Unlike the
    rate above they outlast the window of recent calls, the model
    switches and a restart, so output over seconds is how fast the
    session wrote on average over its whole life.  The UI shows it as
    the session list's Avg tok/s column and in the tooltip of a task
    card's title (`harness-ui-session-average-rate`), and the current
    rate stays in the tooltip.
- Live token count: a running session's token figures, its context in
  use and its output, grow while its model streams instead of only
  when its provider reports usage.  Counted here in the harness process,
  in memory, for every provider.
  - From `agent/turn-started` the count starts from the session's
    totals: `:output`, and `:context` plus `:last-output`.
  - Between reports it estimates what streamed since the last one: a
    token for every four characters of text and thinking
    (`agent/stream`) and of tool-call input (the `tool-input` activity's
    `:chars`, counted per tool), plus thinking whose text does not
    stream (Claude Code's) by the clock, at the session's output rate,
    else 40 tokens a second.
  - Each report replaces the estimate with real numbers, so nothing
    counts twice: a hosted loop's `agent/call-usage` adds the call's
    output and, with `:context`, restarts the context from the call's
    prompt; a `session/usage` record sets the figures to the new
    totals.
  - Interface: `usage/live SID` returns `(:context N :output N
    :estimated N)` while SID's turn runs, else nil; ESTIMATED is how
    many of their tokens are the estimate.  `usage/live-all` returns
    every running session's, each with `:session`.  Changes trigger
    `usage/live-updated SID LIVE`, which ACP forwards, at most every
    `harness-usage-live-interval` seconds a session (0.25), the changes
    in between together; thinking without text announces every
    interval while it lasts.  `agent/turn-ended` sends the last figures,
    then `usage/live-updated SID nil`: the session's totals count again.

### insights

The Insights report: how a period of work with the agents went, after
Claude Code's `/insights`, from the harness's own records only
(transcripts, the usage database, the task board, its own permission
decision log), so it is the same for every provider.  Methods are
`_harness/insights/...` over ACP.

- `insights/compute &key since until project period` → promise of the
  REPORT.  SINCE and UNTIL are float times (SINCE nil: all time; UNTIL
  nil: now); PROJECT a directory, normalised to its main checkout
  (`harness-files-owning-checkout`), its git worktrees with it, nil every
  project; PERIOD names the period for the summary's cache.  A compute
  of the same period and project already running is shared, and a
  report is memoised for `harness-insights--memo-age` seconds.
- The transcripts are read by a child `emacs --batch` loading this
  module (`harness-insights-scan-main`, input and output as JSON files
  named by `HARNESS_INSIGHTS_INPUT`/`HARNESS_INSIGHTS_OUTPUT`), so the
  harness process never waits on them; it is killed after
  `harness-insights--scan-timeout`.  The sessions it reads are those
  `session/list` says lived in the period, but for the internal ones
  (`session/internal-start`): the harness's own model calls are no work
  of the user's.  A node is counted in the log
  of the session that made it (`:session`), so a fork's copy of its
  parent's history is not counted twice; a fork's settling results
  (`:meta :forked`) are not activity.  A failed scan leaves a REPORT
  with `:scan-error` and empty session figures; usage and tasks stand.
- REPORT = `(:since :until :project :period :generated :scan :scan-error
  :sessions :session-list :busiest-sessions :tools :tool-totals
  :permissions :activity :projects :usage :tasks :narrative
  :narrative-mode)`:
  - `:sessions (:active :turns :messages :active-seconds :by-kind)`.
    MESSAGES are the user nodes with no sender (`:meta :from`), the
    user's own; TURNS the user nodes that are not steering;
    ACTIVE-SECONDS add the gaps between a session's nodes up to
    `harness-insights--idle-gap` (600 s).
  - `:session-list`/`:busiest-sessions` rows `(:id :name :kind :project
    :main :model :prompt :turns :messages :tools :errors :denied :active
    :first :last :task)`, by active time.
  - `:tools ((:tool :calls :errors :denied :interrupted :seconds
    :unanswered))`, most called first, from tool-result nodes:
    `:meta :denied`, `:meta :interrupted`, `:is-error`, and
    `:meta :duration` for SECONDS; calls the harness made for a user
    (`:meta :from`) are left out.
  - `:permissions (:decisions :allowed :denied :asked :asked-allowed
    :asked-denied :first :tools)` from the decision log (below).
  - `:activity (:hours :weekdays :active-days :longest-streak
    :longest-streak-end :current-streak :busiest-day)`: the user's
    messages by local hour (24) and by weekday from Monday (7), the days
    with any, and the busiest, `(:day "YYYY-MM-DD" :messages N)`.
  - `:usage (:totals :by-model :by-provider :projects :series :bucket)`:
    `usage/totals`, `usage/summary` and `usage/series` with the same
    SINCE and UNTIL as the usage dashboard asks, a PROJECT as
    `:projects`, the roots `usage/summary :group-by project` says
    belong to it, so the figures are the dashboard's.
  - `:tasks (:submitted :completed :merged :first-try :sent-back
    :feedback-rounds :failed :cancelled :duplicates :conflicted
    :mean-time :median-time :open :notable)`: from `task/list`, every
    task loaded, archived ones included (a PROJECT's repository store is
    read first, as its board would).  CONFLICTED counts merges the merge queue told about
    a conflict (its messages to the task's session); OPEN the board's
    columns now, `((:column :count))`; NOTABLE at most ten
    `(:id :title :session :state :column :outcome :why :feedback
    :conflict :created :done-at)`, WHY one of failed, sent-back, review,
    done.
- `insights/projects` → the main checkouts of every session's and
  task's project, sorted: what the report can be narrowed to.  A git
  worktree is no project of its own, a task's, which a task made from
  inside a worktree has for its project, included, and nor is a scratch
  directory in a session's temporary directory, such as a sub-agent's
  working directory: its work counts for the project of that session
  (`harness-project-main`), and for none once the session is gone.  An
  internal session's project is not counted for that.
- `insights/narrative &key since until project period refresh` →
  promise of `(:summary :themes :patterns :friction :suggestions :model
  :at :stale)`, or `(:skipped TEXT [:error t])`.  A model of the user's
  provider (`harness-insights-model`, `auto` the simple tier of
  `harness-model` as configured for the project) gets a digest of the
  REPORT (figures, and each session's kind, name and first request,
  at most `harness-insights--prompt-chars` characters) and answers in
  JSON.  One `provider/complete` call, `:ephemeral t`, `:no-thinking t`,
  in `insights/` under the state directory, cancelled after
  `harness-insights--narrative-timeout`; it is recorded as an internal
  session, "Insights summary", in the project, which records its cost
  too (without the session module the cost is recorded with
  `usage/record` under the project, or none).  Summaries are kept in
  `insights/narratives.json` by period and project
  (`harness-insights--narratives-kept`); a kept one younger than
  `harness-insights-narrative-max-age` is returned unless REFRESH.  A
  failure is not retried for `harness-insights--narrative-retry`
  seconds unless REFRESH.  `harness-insights-narrative` nil skips it,
  and the REPORT says so in `:narrative-mode`.
- The decision log: `permission/requested` notes when a call was asked
  about, and `permission/decided` appends `(:ts :session :tool :behavior
  :asked)` to `insights/permissions-YYYY-MM.jsonl` (store), when
  `harness-insights-record-permissions`.  Months older than
  `harness-insights--permission-months` are deleted at init.
- The demo provider writes the summary from the digest, so the tests
  and the dev daemon run offline.

### fallback

When a provider runs out of quota or money, its sessions carry on with
another.  A session's own model -- the one it was given: the default
model, one picked by hand, a task's -- always comes first, and the
fallback never moves a session off it while it works.
`harness-fallback-models` (global, *Models and services*) is the order
of preference among what a session carries on with once its own model
is out, first used to last: each entry a provider id, standing for that
provider's model of similar ability (the tier of the session's model,
see `provider/model-tier`, or the nearest tier that provider has a model
for, weaker first), or a model id used as it is.  A setup that prefers
Claude puts the default model on Claude, the list naming what comes
after it.  nil turns the switching off; running out is still noticed,
shown and hinted.

- Marks: a provider that ran out is marked, the whole provider (key
  `"deepseek"`) or one model (key `"claude:claude-fable-5-1"`, when only
  a window scoped to a model is used up).  MARK = `(:key :provider
  :model :kind quota|billing :reason TEXT :since F :until F :source
  error|quota)`.  `:until` is when the limit resets, when known, else
  an hour on (`harness-fallback--retry-after`); a mark ends then, or
  when the user clears it, and a timer announces it.  Marks persist in
  fallback.json.
- What counts: a failed step whose FAILURE (see `agent/step-error`)
  has `:error-kind` `quota` or `billing`, or, without a kind, whose
  error text reads as running out of quota or money (HTTP 402,
  "insufficient balance", "usage limit", "hit your limit",
  `insufficient_quota`...; `harness-fallback-error-kind`).  A
  rate limit, an outage or a refused login never does.  Also
  `provider/quota-updated`: a plan window used up (used >= 1, resetting
  later), unless the plan's extra usage pays for calls, marks the
  provider until it resets (a window scoped to a model, that model);
  such marks follow the quota and go when it says calls work again.
- Choosing: the models to try are the session's own model, then the
  entries of `harness-fallback-models` in order (an entry standing for
  the own model itself is left out).  A session moved by the fallback
  remembers its own (`:original`).  The first model of that order that
  is neither marked nor that of an unregistered provider, and which the
  provider's catalogue does not deny, wins; the session's own model is
  judged only by whether it is marked, so a session whose own model
  works stays on it.  `harness-fallback-choose SESSION` returns
  `(:model ID :back BOOL :entry ENTRY)`, or nil.
- Switching: `agent/before-turn` (priority 10, before compaction)
  moves a session whose model is out to the chosen one; a session moved
  earlier moves back up to a higher entry once that works again while
  its own model is still out, and back to its own model once that does;
  `agent/step-error` marks what ran out, moves the session and retries
  the step, so a turn, and a task, carry on.  The model changes through
  `session/update` (`:silent`) with a hint of its own ("Claude Code is
  out of quota until 19:00, so this session carries on with
  DeepSeek-V4-Pro."), and `fallback/switched SID FROM TO WHY`: WHY `out`
  (the model left ran out, with its mark), `up` (a more preferred entry
  works again while its own model is still out) or `back` (its own
  model again).  A model changed by
  anyone else forgets the session's own; a fork takes over its
  parent's.  With nothing left the turn ends with its error and a hint
  naming every provider that is out and when it resets.
- Notifications (`notification/send`, source "fallback"): low urgency
  when a provider runs out and sessions move on, normal when nothing is
  left.
- `fallback/status` → `(:models (ENTRY …) :marks (MARK …) :moved
  ((:session SID :original MODEL :model MODEL) …) :enabled BOOL)`,
  ENTRY = `(:entry STRING :provider ID :model MODEL-OR-NIL :label
  :provider-label :registered BOOL :mark MARK-OR-NIL :tiers
  ((:tier "simple" :model ID :label … :out BOOL [:thinking LEVEL]) …))`,
  `:tiers` for a provider entry only: the model of each of its four
  tiers, and the thinking level the tier names, if any.
  `fallback/clear KEY` forgets the mark KEY (a provider's forgets its
  models' marks too); → non-nil when one went.
  `fallback/mark KEY &rest (:kind :until :reason)` marks by hand.
  Event `fallback/changed` after any mark or session record changes.

### retry

A step that failed because the network hiccuped -- a connection reset,
an empty reply, a timeout, a gateway's 502 -- or because the provider
asked the caller to slow down, is tried again on the same provider.
The HTTP layer already retries a request whose failure nothing reached
the caller from (`harness-http--retry-delay' below), so what this module
sees is a failure that got further: a stream cut in the middle of the
answer, or a transport failure that outlived those tries.

- What counts: a failed step whose FAILURE (see `agent/step-error`) has
  `:error-kind` `transport` (`harness-provider-openai' names a 5xx, a
  connection-level failure curl reported, and a stream that ended
  without headers that way) or `rate-limit` (HTTP 429), or, without a
  kind, whose error text reads as one of those
  (`harness-retry--transient-text-p`: "connection reset", "empty
  reply", "could not resolve", "timed out", "rate limit"...).  Quota
  and billing failures are the fallback module's and are never answered
  here; neither is a failure another handler already answered.
- Bounded: at most `harness-retry-max-attempts` (3) times per turn; the
  count resets when a turn starts.  The wait before each try doubles
  (`harness-retry-delay`, 1s, doubled, spread by
  `harness-retry-jitter`), capped at `harness-retry-max-delay` (30s)
  and never shorter than the `:retry-after` a rate limit asked for.
  Each wait, and the giving up, is a hint on the session
  ("network error: the connection was reset by the peer (curl 56: ...);
  trying again in 2 s (1 of 3)").
- `agent/step-error` filter at priority 60, after the fallback (50), so
  a provider that ran out is moved before this module is asked.
- A step tried again runs with the partial answer the failed one
  streamed already dropped by the agent (`session/discard-nodes'), so
  a retry cannot duplicate content.  A turn cancelled while it waits
  tries nothing (`harness-retry--wait').

The HTTP layer's own retries (`harness-http'): a request that failed
transiently -- curl exits 6, 7, 28 before the response began, 35, 52,
55, 56 -- and of which no body byte reached the caller is tried again
`harness-http-max-retries' (3) times, waiting `harness-http-retry-delay'
doubled, capped at `harness-http-retry-max-delay' (15s) and spread by
`harness-http-retry-jitter'; the delay a retryable response (408, 429,
500, 502, 503, 504) asked for in Retry-After is a minimum.  A request
streams when it has an `:on-chunk' function: a retryable response is
then not retried by the HTTP layer (the step layer does it), and a
request whose body already reached the caller is never retried at all.
`harness-http-request' takes `:retry' (`t' for any method, a number, 0
for none; nil retries a GET or a HEAD only), and a download is started
over, partial file deleted, when a transfer is cut
(`harness-http-max-retries' times by default).  A cancelled request and
a request whose own timeout fired are never retried.

The providers that speak HTTP ask for it: the OpenAI-compatible ones
(DeepSeek included) and Bedrock pass `:retry t' for every completion.
So a lost connection is repeated for the harness's own calls -- a
task's title, a permission judge, a recap -- which no step layer covers
(they are no agent step), as well as for a turn's.  The Claude Code CLI
retries its own API calls.

A CLI provider's process killed by a signal mid-turn (its failure text
reads "exited with status N" for N in 6, 9, 11, 13, 15, 134, 137, 139,
141 or 143: SIGABRT, SIGKILL, SIGSEGV, SIGPIPE, SIGTERM, by number or
as a shell reports them, 128 + the signal) is the kind `process`
(`harness-retry--process-death-patterns`), retried like a transport
failure with the hint "the provider's process died: ...".  The next
try starts the process again.  An exit the program chose (status 1 and
a message, an invalid key) is not retried.

### resilience

Sessions and sub-agents never sit stalled unless the user stopped them
on purpose.  In the core (`harness-core-modules`), after session, agent
and tools.

- After a start (not a reload: `harness-module-ready-p`), from
  `harness-run-soon`, `harness-resilience--recover` goes over
  `session/interrupted` (see session).  A session whose owner carries it
  on is left to it: a task's (`task/for-session`, see
  `harness-tasks-resume-interrupted`), an internal one, and a
  sub-agent no `spawn_agent` call started (a supervisor's worker, the
  merge queue's resolver, a seed: the module that started it).  Any
  other is sent a message of the harness's (`agent/prompt`, `:from`
  `(harness-sender-system "restart")`) naming the tool calls that did not
  finish and the prompt it waited on, unless
  `harness-resilience-resume-interrupted` is nil, its turn was
  cancelled, or it was carried on `harness-resilience--resume-max` (3)
  times in a row already; then it gets a hint saying why, and the user a
  notification (kind `left-stopped`), but for a cancel.
- Cancels: `agent/cancelling` sets the session's ext
  `:resilience-cancelled`, which the next `agent/turn-started` drops, so
  a turn cancelled on purpose -- `C-g`, a cancel action, another
  session's `session_control` -- is never carried on, however the
  process ended after.  An exit does not cancel turns (SIGTERM runs
  `kill-emacs-hook`, which saves them as they are), so one restarted
  with `M-x harness-restart` carries on.  The count of
  carries in a row is the ext `:resilience-resumes`; a turn ending
  `end-turn` drops it.  Both are in the record, so they outlive the
  process.
- Waits: at `agent/turn-ended` the ext `:resilience-awaiting` keeps
  what `agent/outstanding` says the session still waits for (a
  sub-agent, a `session_wait`, an event watch).  Those registrations
  live in the process; after a start, a session that still has the
  mark, waits on nothing of this process and was not carried on is
  woken with a message saying so (`harness-resilience--wake-waiters`).
- Sub-agents: tools-agent keeps the ext `:report-to` (parent, name,
  worktree, branch) on each child it spawns, until the child reported.
  At a start it takes those children back (`harness-tools-agent--adopt`).
  Once this module has carried on what it carries on, it reports the
  ones not running (`harness-tools-agent-settle-adopted`); without it,
  tools-agent does `harness-tools-agent--settle-delay` (60 s) after the
  start.  One that is carried on reports when its turn ends, as always;
  one that is not is reported "stopped: the harness restarted during its
  turn, which was not resumed" (or cancelled), so no parent waits
  forever.
- Prompts: every `harness-resilience--tick-seconds` (30) a repeating
  timer looks at the blocked sub-agents.  A pending request older than
  `harness-resilience-prompt-timeout` (600 s; nil never) is answered by
  default: a permission denied for that call alone (`permission/answer`,
  with a reason telling the agent not to wait for it), an ask_user
  question answered "decide for yourself" (`question/answer`), a
  question the harness asked dismissed (`question/cancel`).  The parent
  is told by a message when the child is `spawn_agent`'s, by a hint
  otherwise; the user by a notification (kind `prompt-timeout`); event
  `resilience/prompt-timed-out ID ITEM`.  The user's own sessions and
  tasks always wait for the user.
- Watchdog: the same tick looks at the running turns.  Progress is any
  of `agent/step-started`, `agent/stream`, `agent/tool-call`,
  `agent/tool-result`, `agent/activity-changed`, `agent/steered`,
  `tools/progress` and `session/pending-changed`; a session blocked on
  the user is not stalled.  One quiet for `harness-resilience--stall-after`
  (900 s; nil turns it off), or while tool calls run their longest
  timeout and 60 s more when that is longer, gets a hint, event
  `resilience/stalled ID SECONDS`, and the user a notification (kind
  `stalled`), once until it moves again.  It is reported, not cancelled:
  only the user knows whether a long silence is a hang.
- Notifications go through `notification/send` when the notifications
  module runs, else straight to the UI (`client/request`
  `_harness/client/notify`), else to the log.

### compaction

- `compaction/compact SESSION-ID &optional OPTS` → promise of the
  `compaction` node, which stands in for the conversation from then on:
  `session/messages` starts at it, as a user message, followed by the
  unanswered user messages carried over after it.  OPTS `:kind` (one of
  `harness-compaction-kinds`) says what it holds:
  - `summary` (the default): the session's model (OPTS `:model`
    another) summarises the conversation, and the message reads
    "Summary of the conversation so far: ...".  OPTS `:context` is
    `full` (the default) or `sample`, which sends the conversation's
    narrative — every user and assistant message, each tool call and
    result in one line, never a payload — so a summariser that has to
    be sent the conversation as text never takes its payloads at once.
    A summary of a sample is a brief one.
  - `brief`: a summary of a sample, written by OPTS `:model`, else
    `harness-compaction-brief-model` (`auto`, the default: the simple
    tier of the session's provider, `provider/tier-model`, else the
    session's model; nil: the session's model; or a model named), and
    ending in a note that it was written from the conversation's
    narrative, tool calls and results named in a line, and so lacks
    what they carried
    (`harness-compaction--brief-caveat`; OPTS `:caveat` replaces it, nil
    for none).  It costs cents however long the conversation.  A
    handoff's `compact-new` is one, written by the new model.
  - `transcript`: no request.  `session/write-transcript` writes the
    conversation to a file in the session's directory, and the node
    holds a note, sent as it is, saying where the file is and how long,
    and to read its end and its start before answering, then what it
    needs of the rest.
  - `fresh`: no request and no file.  Nothing of the conversation is
    carried over: the node holds a note saying how many messages of
    about how many tokens came before it and that they are not carried
    over, and telling the model to look back at what it needs with
    session_history (`harness-compaction--fresh-note`), or, without
    that tool, to ask the user.
  - `truncate`: no request and no file either.  The oldest nodes are
    dropped and the most recent ones are kept, as they were, whole tool
    exchanges at a time: the nodes are chosen newest first
    (`harness-compaction--truncate-plan`, `harness-compaction--node-units`)
    up to `harness-compaction--truncate-keep` of the usable window and
    re-appended after the node, which carries a note
    (`harness-compaction--truncate-note`) saying how many nodes of
    about how many tokens went and that the most recent are kept below.
    It is what a conversation too big to summarise gets: nothing has to
    be read to make it, and `:meta` records `:truncate-dropped`,
    `:truncate-kept` and `:dropped-tokens`.  It refuses (`harness-error`)
    when nothing would be dropped, since then there is nothing to cut.
  Every kind but `fresh`, whose note says so already, ends in a line
  pointing the model at the session_history tool
  (`harness-compaction-history-tool`, `harness-compaction--history-note`):
  the conversation it replaced is still on record.  The line is left
  out when the session's model does not have the tool
  (`harness-compaction-history-p`, from `tools/list`).
  A model-written compaction (`summary` or `brief`) also keeps the
  conversation's first message and its most recent one verbatim in the
  node (`harness-compaction--verbatim-ends`), so a short task and the
  latest message survive the summary; the cost estimate's `:after`
  counts them.
  The node's `:meta` points at the compacted head and records the kind
  (`:compaction`, read back by `harness-node-compaction-kind`), the
  writer (`:model`, the session's for a transcript), what it was given
  (`:context`), the size compacted, a transcript's `:file` and OPTS
  `:meta` (a handoff's `:handoff`); hints say it began and what it
  became.  A summariser whose provider keeps the conversation and can
  fork it (a hosted loop) works on a fork of the session's provider
  state, so it summarises the real conversation and leaves the
  session's own alone; one whose provider is sent the transcript anyway
  (an API provider) gets it as messages.  A summariser that keeps the
  conversation and has no state of this session (the target of a
  switch, a cheap model's side request) is sent the context inside one
  message as structured text.  Every compaction starts the
  conversation over (`harness-compaction--start-over`): its usage
  record carries `:cache-reset`, so the session reports no prompt
  cache (see "Session"), and the provider state of the session's model
  goes (`session/set-provider-state` nil, which closes a hosted loop's
  process), so a hosted loop's next request opens a new conversation
  with the compaction instead of adding it to the old one, whose
  context is what compacting was for.  The state of another provider,
  left by a handoff, stays.  One compaction runs per session at a time,
  a second call returning the running promise.  OPTS `:idle` refuses a
  session running a turn (`agent/running`), whose turn would go on
  writing after the conversation it replaces, as compacting by hand
  does.

  OPTS `:queue` and `:interrupt` are for just that session instead of a
  refusal.  While a turn runs, `:queue` records the compaction in
  `harness-compaction--pending` and returns at once -- it must not wait
  for the compaction, since the compaction waits for the same turn: the
  promise resolves to `(:queued t :kind KIND :interrupt BOOL)`, never to
  the node the compaction later appends.  `:interrupt` also cancels the
  running turn (`agent/cancel`) after storing the entry, so the
  compaction runs once the turn is over; the step in flight and
  anything it had not recorded are lost.  The queued compaction runs at
  the session's next boundary: the `agent/step` and `agent/before-turn`
  gates (`harness-compaction--gate`, priority 12, ahead of cowboy's 15
  and automatic compaction's 20, so the fresh context is what those see)
  run it, or, for a turn that ends first (a `cancelled` one included),
  the `agent/turn-ended` handler does.  A `:queue` or `:interrupt` call
  to an idle session compacts at once, like any other.  A compaction
  already waiting is replaced; the pending entry lives in the harness
  process and is dropped when the session is.
- `compaction/estimate SESSION-ID` → `(:context :model :model-label
  :messages :cached :carry-on :carry-on-cached :compacting :kind
  :kinds)`: the context the next message sends, how many messages it
  holds, whether the prompt cache still lasts
  for the session's model, what that message costs as things are and
  read from the cache, whether a compaction runs, and the configured
  kind; `:kinds` has `(:kind :model :model-label :input :output :cached
  :cost :after)` per kind, at list prices (`usage/price`, so a
  time-of-day price applies; nil without one).  A summary reads the
  whole context, from the cache only on a fork of a hosted conversation
  whose cache is warm, else at the uncached rate: the higher of the
  cache-write and the input price, as a provider that does not charge
  for writes (DeepSeek, priced 0) still charges the input.  A brief
  summary reads the system prompt, the sample and the ask; either
  writes up to the summary's budget
  (`harness-compaction--summary-output`).  A transcript, a fresh start
  and a truncation cost nothing and leave their note (`:after`) in place
  of the context; a truncation's entry also carries `:kept` and
  `:dropped` (how many nodes each) and `:kept-tokens` and
  `:dropped-tokens`, with `:after` the note plus what is kept, and
  `:dropped` 0 when nothing can be cut (`:after` is then the context).
- `compaction/resend-cost SESSION-ID` → `(:context N :model MODEL
  :cached USD :uncached USD)`: what sending the context costs read from
  the model's prompt cache and not (the dearer of cache write and input),
  at list prices, nil where the catalogue has none -- the two numbers of
  `compaction/estimate`'s carrying on, without the rest of it.  Keeping a
  cache warm weighs one against the other (cache-warm).
- Settings (section "Compaction"): `harness-compaction-kind`, the kind
  automatic compaction makes (`summary`; any of the kinds, `truncate`
  included), and `harness-compaction-brief-model`.
- Auto: `agent/before-turn` compacts, as `harness-compaction-kind`
  says, when the context comes within
  `harness-compaction--context-reserve` of the window unless the provider
  reports `:compaction hosted`.  The window is the session's
  (`:context-window' override, else its model's, capped by its
  `:context-window-limit'), so a session capped below its model's
  window compacts at the cap, which is how task sessions compact
  earlier (`harness-tasks-context-limit', 384k tokens by default).
  It judges the session as it is then, read again: the fallback,
  earlier in the chain, may have moved it to another model.

### cowboy

What a message to a session whose prompt cache went cold does first.
The quick compaction the switch banner offers on a switch of provider,
made part of every turn: whoever sent the message (the user, a task's
feedback, another session's agent, the merge queue), it is not sent
as it is, all of the conversation uncached, without a decision.

- Async filter on `agent/before-turn` at priority 15: after the
  fallback and a handoff (10), which may change the model or start the
  conversation over, before automatic compaction (20), which would
  summarise on the session's model, reading it all uncached.  It reads
  the session again and goes on untouched unless `harness-cowboy-cold-p`:
  the `:cache` (see "Session") expired, the session has a head, and its
  context is at least `harness-cowboy-min-context` (0).  A session with
  no `:cache` never is.  A cache a redaction dropped has expired from the
  drop on (`:expires` is `:dropped`, see "Session"), though its provider
  would have kept it longer: the session's provider conversation went
  with the secret, and its next message would send the whole transcript
  as a new conversation's first message, uncached.  So the gate asks
  right after a redaction, or takes the default for a session nobody is
  asked about, as for any cold cache.
- The choices (`harness-cowboy-choices`): `brief`, `summary`,
  `transcript` and `fresh` compact as `compaction/compact` does, with
  `:meta (:cowboy (:choice C :by BY))`, before the message; `carry-on`
  sends the conversation as it is and says so in a hint; `ignore` sends
  it as it is and adds nothing at all (no hint, no compaction, no
  status change); `hold` stops the turn (`:proceed` nil, reason "not
  now: …"), the message staying in the transcript to go with the next
  one.  A summary that fails falls back to `transcript` (`:fallback` in
  the meta), and that to `carry-on`, each said in a hint: the message
  always goes unless held.  A hint says what went first and why ("as
  you chose", "the default for a session that does not wait for you",
  …), except for `ignore`, which leaves no hint.  While the compaction
  runs the session is `running` with the activity `(:phase compacting)`
  (`agent/note-activity`).
- Asked unless `harness-cowboy-ask` is nil or the session is
  non-interactive (the policy's `harness-non-interactive`, else the
  session's own `:non-interactive`, else the config, as perms decides):
  `question/ask` puts a question pending on the session, which is
  blocked on it.  Its payload holds the question, the options with
  their costs (`compaction/estimate`), `:allow-free-text`, the message
  waiting as `:waiting-message` `(:text :from)`, and `:cowboy`: `(:at
  :ttl :expires :dropped :cache-model :model :model-label :context
  :messages :carry-on :carry-on-cached :from :preview :default :history
  :choices)`, each choice `(:choice :label :what :cost :cost-text :by
  :after)`.  `:dropped`, when a redaction dropped the cache, is the
  moment, and then the question says so ("a redaction dropped this
  session's provider conversation at HH:MM, so no prompt cache holds
  it") and names no cached price to compare with: none can be had; the
  hint after the choice opens "Prompt cache dropped at HH:MM by a
  redaction".  Clients that know it draw it (ui-cowboy); the others show
  an ordinary question.  The answer is read by
  `harness-cowboy-parse-answer`: a choice's name, label, option as
  offered, number, key or words naming it, and "always" with any but
  `hold` makes it the default and turns asking off (`config/set` of
  `harness-cowboy-default` and `harness-cowboy-ask`).  An answer that
  names no choice asks again; a dismissed question holds the message.
  `session_control` refuses to answer it for another session's agent.
- An "always" answer is a lasting decision of the kind `cowboy` (see
  "decisions"), its record `(:choice C :before SETTINGS :after
  SETTINGS)`, each SETTINGS `(:default C :ask BOOL)`; the hint written
  then has its id in `:meta` `:decision`.  Undo sets the settings back
  to `:before` (asking on, the earlier default) while they hold
  `:after`; redo sets `:after` while they hold `:before`; else the
  decision ends `changed`, the settings left as they are.  A hint of
  the default taken unasked (BY `default`, `non-interactive`,
  `unasked`, `cold-start`) names the decision whose `:after` the
  settings hold now as `:decided-by` (`harness-cowboy--live-decision`).
- Not asked, `harness-cowboy-default` goes first (`brief`, the one
  choice that never reads the whole conversation uncached and still
  leaves a summary).  No model judges the choice.
- `agent/cancelling` or `agent/turn-ended` while the question waits
  dismisses it; `session/deleted` lets the turn go.  A harness that
  stops while it waits loses the turn, not the message: settling the
  session at the next start (`harness-session--settle`) queues the
  `:waiting-message` again, with a hint saying so.
- `cowboy/asking SESSION-ID` → the id of the question the session waits
  on, or nil.  Events `cowboy/asked SID PID` and `cowboy/decided SID
  CHOICE BY`, BY one of `user`, `always`, `non-interactive`, `default`
  (asking off), `unasked` (the question could not be asked) and
  `cold-start` (`cowboy/compact`, below).
- `cowboy/compact SESSION-ID &rest OPTS` → a promise.  What the gate
  does for a session nobody is asked about, for a caller that made a
  session whose conversation no warm cache holds, before its first turn
  (a fork has no `:cache` of its own, so the gate never finds it cold).
  With `harness-cowboy-min-context` above 0 and a context
  (`compaction/estimate`) under it, it does nothing and resolves nil,
  with no hint.  Otherwise it takes `harness-cowboy-default` (never
  `hold`), emits `cowboy/decided SID CHOICE BY`, adds a hint (none for
  `ignore`) and, unless the choice is `carry-on` or `ignore`, compacts
  as the gate does (`:meta (:cowboy (:choice C :by BY))`, the
  fallbacks included).  It does not mark the session busy: no turn is
  running.  It resolves with the choice taken,
  a symbol, and never rejects: an error is logged and resolves nil.
  OPTS: `:by` SYMBOL, BY, default `cold-start`; `:why` STRING, which
  opens the hint in place of "Prompt cache cold since HH:MM", a time a
  session with no cache could not give (for example "No prompt cache on
  MODEL holds the supervisor's conversation").  The hint ends "the
  default for a session no warm cache holds (harness-cowboy-default)".
- `cowboy/default [SESSION-ID]` → `(:choice CHOICE :ask BOOL :asks BOOL
  :decision ID)`: the compaction option the user saved for a cold cache --
  `harness-cowboy-default` (never `hold`), whether the question is asked
  at all (`harness-cowboy-ask`), whether a message that met SESSION-ID's
  cold cache would be asked about (`:asks`: asking is on and the session
  waits for the user, which a non-interactive one never does; without a
  session it is `:ask`) and the "always" answer's decision that set them
  while it still holds (`harness-cowboy--live-decision`), nil otherwise.
  What acts for the user where a cold cache is concerned, and only where
  nobody would be asked, takes the choice from here (cache-compact).
- Settings (section "Cold cache"): `harness-cowboy-ask`,
  `harness-cowboy-default`, `harness-cowboy-min-context`.

### cache, cache-warm, cache-compact

A provider's prompt cache lapses some minutes after the request that
last read it, and what is in it is then sent again at the uncached price.
Two things are worth doing with a cache that is about to lapse while the
context is still hot in it, and neither should watch the clock itself:
the `cache` module does, and says when (`cache/pre-expire`); `cache-warm`
reads the cache once more, which restarts its lifetime, for as long as
that pays; `cache-compact` compacts the conversation in it, as the user
saved for a cold cache, once nobody is around to need it warm and where
nobody would be asked what goes first.

**cache** (harness-cache.el) -- the watcher, and whether the user is around.

- One timer per session whose `:cache` (see "Session") will lapse, set
  for LEAD seconds before it and set again on every `session/changed`
  from the `:cache` as it is then: a request that read the cache moves the
  moment, a compaction, a redaction, a switch of model, a deleted session
  take the timer away.  Nothing polls.  `cache/pre-expire SESSION-ID INFO`
  comes once for each moment a cache lapses, INFO `(:expires :ttl :lead
  :at :model :context :status :running)`; never for a cache that lapsed
  already or has under `harness-cache--too-late` (2) seconds left, so a
  machine that slept through the moment says nothing when it wakes.
  `cache/watching SID` → `(:fire-at :expires :lead)` or nil.
- Handlers that would act on the same cache claim it: `cache/claim SID BY`
  → non-nil if it is BY's (the first wins), `cache/claimed SID` → BY or
  nil.  A claim is good for the moment it was made for; the request that
  reads the cache ends it.  Handlers run by priority: cache-warm 40,
  cache-compact 60.
- The periods are formulas of the cache's lifetime T (`cache/periods
  TTL` → `(:ttl :lead :active :grace :warm)`), so a 37-minute or an
  hour-and-a-half cache behaves as a five-minute or an hour's: LEAD =
  T/30 bounded to 10..60 seconds and to half of T (10 s at five minutes,
  60 s at an hour); ACTIVE = T/5 (1 minute, 12 minutes); GRACE = T/3 but
  not under 5 minutes (5, 20); WARM = ACTIVE + GRACE (6, 32 minutes; 19 for
  37, 48 for 90).
- The user is around for the WARM period after a sign of life: a message
  they send (the sync filter `agent/message`; not another session's, the
  harness's, or the queue's), the answer to a question (`question/answered`),
  and `cache/active SID &optional SECONDS` from a client -- the chat reports
  typing and any command in the session's buffer, twenty seconds apart at
  most.  SECONDS above 0 is a period the user asks for, whatever happens
  (they know they will be back), a day at most; 0 takes it away and is no
  sign of life.  `cache/presence SID` → `(:session-id :around t :until
  :active-at :manual-until)` or nil; the event `cache/presence-changed SID
  PRESENCE` (nil once they are not) announces every change, and a timer
  closes the period.  Nothing of this is kept across a restart.

**cache-warm** (harness-cache-warm.el) -- keeping the cache alive.

- Handles `cache/pre-expire` at priority 40.  It reads the cache once more
  when `harness-cache-warm` is on and the user is around, or the turn
  waits on a tool call (`agent/activity` phase `tool`, a long test run
  say: the step after the tool will send the whole conversation, whoever
  is around), and the session has a cache, can be asked to, was not stopped
  and is not capped, no refresh is under way and no hard budget forbids
  it (`usage/budget-block`); it claims the cache first.
- What is sent: for a session that waits for the user, the request the
  agent's next step would send (`harness-agent-step-request`: model,
  system prompt, tools, thinking, conversation) with one short message at
  the end (`harness-cache-warm-message`) and `:max-tokens` 16, flagged
  `:cache-refresh t`; for a turn that waits on a tool call, the request of
  its latest step (`harness-agent-last-request`) again, so that it reads
  the very cache that step wrote.  Providers that are sent the whole
  conversation at every request (Bedrock, OpenAI, DeepSeek) can be asked
  both; a hosted loop only when it declares `:cache-refresh`, holds the
  session's conversation and no turn runs: the message is then sent in
  the process that holds it (the Claude provider refuses a refresh that
  could not run in the live process serving the conversation as it is --
  no process, a turn under way, other settings, a forked state), and the
  conversation it holds keeps the two short messages.  Nothing is written
  into the transcript; a user message that comes while one is under way
  waits for it (an `agent/before-turn` gate at priority 1, thirty seconds
  at most); a tool call the model answers with is cancelled.
- The result: the usage of the request is recorded in the session
  (`session/usage-add` with `:cache-at` the time it was sent and the
  lifetime the provider reported or the cache had, no `:context`), so the
  cache is stamped anew and the watcher sets itself for the lapse after
  it: the chain goes on by itself.  A refresh that does not read at least
  half the context from the cache, or whose provider reports no usage, stops
  keeping that session warm (the state's `:blocked`, a hint, until the user
  asks for a period, or the model changes).  A failed one is tried again
  every 3 seconds while the cache lasts, three times, and said once.
- Never worth more than sending the conversation again: at most as many
  refreshes between two requests of the conversation's own as cost less than
  sending the context uncached (`compaction/resend-cost`: a refresh reads at
  the cache-read price; 12 for Claude's, 2 at half price, none where the cache
  reads as dear as the input; 12 where the catalogue has no price).  The
  count starts afresh with the next `session/usage` record that reports a
  request (the module's own do not).  At the cap the cache is left to lapse,
  the state's `:blocked` and a hint say so, once.  The end of the warm period
  the state shows (`:until`) is the earlier of the user's and the cap's.
- `cache/warm SID` → `(:session-id :warming :until :manual-until :active-at
  :next :refreshes :max-refreshes :refresh-cost :resend-cost :tool :ttl
  :expires :supported :blocked)`, nil when there is no period; `:warming`
  says the cache is being kept alive now.  `cache/warm-list` → the states in
  effect.  `cache/keep-warm SID SECONDS` → the state: the period the user
  asks for (`cache/active` with the seconds, and a try again where it was
  stopped).  Event `cache/warm-changed SID STATE` (nil once over), announced
  when `:warming`, `:manual-until`, the counts, `:blocked` change or the end
  of the period moves by 30 seconds; ACP forwards it and clients call the
  methods as `_harness/cache/…`.
- Setting: `harness-cache-warm` (on).

**cache-compact** (harness-cache-compact.el) -- compacting before the lapse.

- Handles `cache/pre-expire` at priority 60, when the cache is not claimed
  (the user is not around, so cache-warm did not take it) and
  `harness-cache-precompact` is on; the session is idle and not a seed (its
  context is shared), with no compaction, question, turn or outstanding
  work (`agent/outstanding`); its context (the last request's) is at least
  `harness-cache-precompact-min-context` (30000) and
  `harness-cowboy-min-context`; the user's saved option (`cowboy/default`,
  which this module requires: with no cowboy module there is none) is a
  compaction -- carry-on and ignore leave the conversation as it is; and
  nobody would be asked: the compaction is what the cold-cache gate does,
  unasked, to the message that comes later, so a session whose user is
  asked what goes first (`:asks`: asking on, the session waits for them) is
  left alone and its question stays theirs.  Answering "always" (which
  turns asking off) or a session that never waits for the user
  (non-interactive) is where it acts.  It claims the cache, then calls
  `compaction/compact` with the
  option's kind (`:idle t`, `:meta (:precompact (:choice KIND :expires T))`:
  the chat says "before the prompt cache lapsed") -- from a hot cache a
  summary reads at the cache price -- and holds a user message that comes
  meanwhile (an `agent/before-turn` gate at priority 11) until it is done.
  A failure is logged and left to the compaction's own hint.
- The note that follows (a hint, "Prompt cache about to lapse at HH:MM:
  compacted into a brief summary, while it was still cached, so the next
  message sends that instead of ~84.0k tokens uncached") tells of a lasting
  decision of the kind `precompact` (`:meta :decision`), `done` while the
  feature is on: [Turn off] undoes it (`harness-cache-precompact` set
  false and saved through `config/set`), [Turn on] redoes it, from any
  session, while the setting holds what the other move left; otherwise it
  ends `changed`.  The one decision serves every note while it holds (the
  newest `done` one whose settings after it are the settings now, else a new
  one is kept).  The note also names, as `:decided-by`, the "always"
  decision that made the saved option the default, with its own undo and
  redo, when there is one.  The event `cache/compacted SID KIND NODE` follows.
- Settings: `harness-cache-precompact` (on),
  `harness-cache-precompact-min-context` (30000); section "Prompt cache"
  of the settings page with `harness-cache-warm`.

### handoff

Switching a session to a hosted loop (Claude Code, Copilot) of another
provider starts a new conversation there, which is sent only the user
messages after the model's last reply: without a handoff the new model
knows nothing of the task.  An API provider is sent the whole transcript
and a provider that still holds the session's conversation resumes it,
so switching to either loses nothing.

- `handoff/check SESSION-ID MODEL` → `(:id :name :from :from-label :to
  :to-label :to-provider :lossy :history :running :reason :risks
  :cache-cost :cache)`.  Lossy when MODEL's provider differs from the
  session's, runs a hosted loop, cannot continue the session's state
  (`session/provider-state`), and the session has history it would
  miss (anything a model or tool wrote since the last compaction) with
  no handoff already waiting for it.  `:reason` says why or why not.
  For a lossy switch `:risks` are `harness-handoff-risks`: a cold prompt
  cache (cache writes where carrying on would read), reduced fidelity
  (the model explores again; tool calls and thinking reach it as text),
  provider state left behind (resume, the provider's own compaction,
  its built-in tools), and that it takes effect at the next step, not
  mid-step; `:cache-cost` prices the session's context at MODEL's
  cache-write and cache-read list prices.  `:cache` is the session's
  (see "Session"): whether the old model's prompt cache still lasts,
  which is what makes it cheap for that model to summarise.
- `handoff/check-all MODEL &optional FILTER` → the checks of the
  sessions `session/set-all` would change (FILTER is `session/select`'s,
  so `:tasks` takes in the sessions of current tasks and `:ids` limits
  the check to the sessions it names, as the session list's model
  switch for its marked sessions does).
- `handoff/switch SESSION-ID MODEL &optional MODE` → promise of `(:id
  :model :from :lossy :mode :summarizer :context :deferred :file :node
  :fallback :error)`.
  The model changes at once (`session/update`); a lossy switch then
  hands over as MODE says, any other is a plain switch.  `compact`
  summarises on the old model (`compaction/compact` with `:model`),
  which reads the conversation from its prompt cache while the cache
  lasts and pays for it all uncached once it lapsed (`:cache`), and
  `compact-new` has the *new* model summarise instead,
  from a bounded context (`compaction/compact` `:kind brief` with
  `:model`: the conversation's narrative, tool calls and results each
  in one line): use it when the old
  provider cannot answer -- its plan ran out, it is down -- or to keep
  the job small.  The compaction node,
  marked `:handoff` with the mode, summariser and context, opens the new
  conversation, ending in a harness note that the handoff is lossy and
  the model should re-investigate rather than trust it.  When no summary
  can be made (the summariser fails or its plan ran out) the transcript
  goes over instead (`:fallback` says why).  `transcript` writes the
  transcript (`session/write-transcript`) to
  `CWD/.harness/handoff/ID-TIME.md` -- in
  the session's directory, which its tools may read and the new
  provider's prompt cache holds as it reads, unlike the state directory,
  and kept out of git by a `.gitignore` of `*` there -- and appends a
  user message from the harness (`:source "model handoff"`, `:meta
  :handoff`) telling the new model to read it before it answers, with
  the same lossy warning.  `none` only switches.  After any of them the
  session reports no prompt cache: a summary starts the conversation
  over (`:cache-reset`), and the new provider, holding nothing of the
  session, starts a conversation of its own whose first request writes
  a cache rather than reading one; a switch that loses nothing keeps
  reporting the old model's cache, which the new model cannot read (see
  "Session").
- `handoff/switch-all MODEL &optional FILTER MODE` → the ids switched,
  of the sessions `handoff/check-all` checks; MODE applies to the lossy
  ones.
- A handoff must land in the trailing user messages.  An idle
  session's starts at once and a turn started meanwhile waits for it;
  a running session's waits for the turn's next step: the
  `agent/before-turn` and `agent/step` gates (priority 10, before
  automatic compaction) run it and hold the step until it is done, and
  a turn that ends first has it run right after.  A handoff waiting for
  a provider the session has left again is dropped.  Event
  `handoff/done SESSION-ID RESULT`.

### naming

- `naming/name SESSION-ID &optional OPTS` → promise of name.  A session
  with no name is named as soon as its first message is sent: on
  `agent/turn-started`, not when the turn ends, since a task's first
  turn lasts until the task is done.  That request (OPTS `(:opening t)`)
  runs beside the turn and holds only the opening message (and the
  latest one when the conversation has moved on since, as a fork's has),
  each cut to 3000 characters, and the question.  It goes to
  `harness-naming-model` (`auto`, the default: the session provider's
  `:simple` tier, `provider/tier-model`) with `:ephemeral t`,
  `:no-thinking t`, a 40-token budget and no provider state, so the
  hosted providers answer it apart from the session's conversation (a
  CLI process of its own for Claude Code, a throwaway session for
  Copilot) and the question never lands in it.  It fails after
  `harness-naming--timeout` (60) seconds, cancelled, so a provider that
  never answers does not keep a session nameless.  A session still
  nameless when a later turn starts (its naming failed) is named then,
  and so is a nameless session whose turn runs when the harness reloads
  (`harness-naming--name-running`); btw, subagent and internal sessions
  never are.  The request names its job, "Auto-name", so the call is
  recorded as an internal session made for the session being named (see
  "provider").
  Without `:opening` the whole
  conversation is titled on the session's model, on a fork of its
  provider state when possible so the cached prefix is reused.  Hints
  "Naming session…" then the result; a session renamed while the model
  was asked keeps its new name.  Events `naming/done SID NAME`,
  `naming/failed SID MESSAGE`.
- `naming/title TEXT &optional OPTS` → promise of a title for TEXT, a
  first message no session holds yet: the same request as `:opening`
  naming, to `harness-naming-model` for OPTS' `:model`, under a pseudo
  session id `naming-…` of its own (`:cwd`, `:host` from OPTS) that is
  `provider/close`d once it settles.  The call is recorded as an internal
  session, "Auto-name", with no parent; nothing else is stored and no
  session hears of it; it rejects with a message (blank TEXT, no model,
  provider error, no usable title, timeout) and never signals.  Task mode names a
  task from its prompt this way as it is submitted.
- Sync filter `naming/system-prompt` (value string, args the session, or
  `naming/title`'s OPTS) lets modules add to
  `harness-naming--base-system-prompt` per session (tasks ask for ticket
  titles, for a session of a task and for OPTS with `:task`).
- Sync filter `naming/auto-p` (value the verdict, args session) can hold
  the automatic naming of a session off: tasks do while the title of the
  session's task is on its way, which then names the session.

### judge

One-off questions to a cheap model, whose short reply the asker reads
as a decision.  emacs_eval's speed judge (tools-emacs-eval) and an
event watch's classifier (tools-events) both ask through this library,
so the request, its retry, its time limit and the lookups a judge may
make before it answers are written once, and a judge differs from
another only in its prompt, its parser and its tools.  The module keeps
no state and starts nothing: its callers `require` `harness-judge` and
do not list `judge` among their modules' requirements, so each of them
loads on its own.

- `harness-judge-model SESSION &optional MODEL` → the model a judge for
  SESSION asks, or nil when none is known: the `:simple` tier of MODEL's
  provider (`provider/tier-model`), else MODEL itself.  MODEL defaults to
  SESSION's `:model`, else to `harness-model` as `config/get` has it for
  SESSION's directory.  SESSION is a session's record, as `session/get`
  gives it, or its id.
- `harness-judge-ask &key session model system prompt tools max-lookups
  max-tokens retry-max-tokens timeout parse label suffix` → promise of
  the answer, which never rejects: `(:value V :text TEXT :lookups N)`
  when PARSE, a function of the reply's text, returns a non-nil V
  (without PARSE, V is the reply trimmed, when it is not blank), else
  `(:value nil :reason WHY :text TEXT :lookups N)`.  WHY is "no model
  could be asked", "it failed: …", "it stopped: …", "it gave no
  answer", "its answer held no verdict: …", "it kept asking for lookups
  past its budget of N" or "it took longer than Ns".  TEXT is the reply
  PARSE read, which is what the judge wrote after its last lookup, and
  N the lookups that ran.  A PARSE that signals finds nothing, and is
  logged under LABEL (`"judge"` by default).
- The request is `provider/complete` with `:ephemeral t` and
  `:no-thinking t`, so a provider answers it from the request alone,
  with no earlier conversation and none kept (see provider), as the
  auto-mode judge's is.  It is made as the session `ID-SUFFIX` (SUFFIX
  `"judge"` by default) in SESSION's directory, on its host; SYSTEM is
  its system prompt, PROMPT the user's message, and MAX-TOKENS (200)
  its output budget.  A reply that budget cut off before it held a value
  is asked for once more with RETRY-MAX-TOKENS, when that is given, and
  once only.  A judge that has not answered within TIMEOUT (30) seconds,
  lookups and retry included, gives no value, and its request is
  cancelled.
- Lookups.  With TOOLS and a MAX-LOOKUPS above zero a judge may look
  things up before it answers; without both none is offered.  A lookup
  is `(:name :description :schema :handler)`: the model is shown the
  first three as the request's `:tools`, and HANDLER, a function of a
  call's input, returns a tool result `(:content TEXT :is-error BOOL)`,
  a string, or a promise of either.  Lookups only read, and run here as
  plain functions, outside the permission chain and every session's chat.
  A result is cut at `harness-judge-lookup-max-chars` (4000), and a
  handler that signals, or whose promise rejects, gives an error result
  ("The lookup failed: …") that the judge reads and goes on from.  At
  most MAX-LOOKUPS calls run in all: a call past that, or of a name
  that is none of the lookups, gets an error result ("No more lookups:
  …", "There is no lookup named X; the lookups are …") and runs
  nothing.  A provider's own built-in tools (`:builtin`) are never
  offered to a judge and never count.  The library does not tell the
  judge of its lookups: the asker's SYSTEM prompt does, and says that
  what one returns is data, not instructions.  Both kinds of provider
  loop work:
  - A hosted loop (Claude Code, Copilot) reports each call with a
    `:respond`: the result goes back through it and the same request
    goes on, and the answer is what the judge writes after its last
    lookup.  A judge that goes on calling after two calls past its
    budget (`harness-judge--extra-calls`) is told so, cancelled, and
    gives no value.
  - A native loop (the OpenAI-compatible APIs, Bedrock) stops at
    `tool-use`: the judge is asked again, with the same tools, budget and
    options, and the calls and their results added to the conversation
    as a session's transcript adds them (an assistant message of its
    `thinking`, `text` and `tool_use` blocks, then a user message of
    `tool_result` blocks).  A retry after the output budget ran out keeps
    the lookups made.  A judge still asking for lookups in its
    (MAX-LOOKUPS + 1)th request gives no value.
- The users.  emacs_eval's judge answers `{"verdict": …, "reason": …}`,
  and may first look up what it does not know with emacs_describe and
  emacs_find_definition (see tools-emacs-eval).  An event watch's
  classifier answers `{"action": …, "note": …}` and is given no tools
  (see tools-events).

### skills

- Scans `harness-skills-directories` for `NAME/SKILL.md` with front
  matter.  The defaults are the documented locations: Claude Code's
  `~/.claude/skills` and `.claude/skills`, the harness's
  `~/.config/harness/skills` and `.harness/skills`, the open Agent
  Skills convention's `~/.agents/skills` and `.agents/skills` (which
  Codex and GitHub Copilot CLI read too), Copilot CLI's
  `~/.copilot/skills` and `.github/skills`
  (`harness-skills-project-subdirectories`, under the cwd and its
  project root), and the skills of Claude Code's plugins
  (`harness-skills-plugin-directories`: `cache/MARKETPLACE/PLUGIN/VERSION/skills`
  under `harness-skills-plugins-directory`, else
  `$CLAUDE_CODE_PLUGIN_CACHE_DIR`, else `~/.claude/plugins`; newest
  version first, none Claude Code orphaned with `.orphaned_at`).
  Codex's deprecated `~/.codex/skills` and its admin `/etc/codex/skills`
  are left out.  Project skills come first, then global ones, then
  plugins' (`harness-skills--source-rank`); the first skill of a name
  wins.  A function in the list may return `(:dir :source :within)`
  plists instead of directories.
- `skills/list &optional CWD`, `skills/search QUERY &optional CWD`,
  `skills/load NAME &optional CWD` → `(:name :description :content :path :source :files)`,
  `skills/refresh`, `skills/expand TEXT CWD` → `(:text EXPANDED :skills (…))`
  (explicit `/name` or `@skill:name` references get the skill content
  attached; the compose UI calls this over ACP).
- `skills/directories &optional CWD` → `(:dir :source :contained)` for
  every directory discovery reads, each followed by the skill
  directories in it that lead elsewhere through a symbolic link (a
  skill linked in from dotfiles).  `:contained` says it holds skills and
  nothing else: a directory a project or a plugin provides counts only
  while it stays inside its `:within` once links are resolved (the
  project root; a plugin's marketplace directory, as Claude Code allows
  links between plugins of one marketplace), and none that is or holds
  the home directory does.  So a link committed to a repository, or
  shipped in a plugin, opens nothing.  The perms module lets every read
  read the contained ones, and the bash tool's sandbox shows them.
- Tools `skill_search`, `skill_load` (`name`, and `file` for one of the
  skill's supporting files, which must stay inside the skill's
  directory and a contained directory once links are resolved, and be
  text; a failure lists the files there are).  Adds a short skills index
  to the system prompt via `agent/system-prompt`.

### worktree

- `worktree/list ROOT`, `worktree/create ROOT &key branch path base`,
  `worktree/remove ROOT PATH &optional FORCE`, `worktree/prune ROOT`,
  `worktree/prune-merged ROOT &optional DRY-RUN`,
  `worktree/lock ROOT PATH &optional REASON`,
  `worktree/unlock ROOT PATH &optional ANY`, `worktree/lock-existing ROOT`,
  `worktree/root-of PATH`, `worktree/branch PATH`,
  `worktree/status PATH` → `(:dirty :ahead :behind :branch)`.  All return promises.
- Sessions created with `:worktree PATH` get `:cwd` = PATH.
- `worktree/list` gives `(:path :branch :head :bare :detached :locked
  :main)` plists, plus `:lock-reason`, `:prunable` (git would prune it)
  and `:missing` (its directory is gone) when they apply.
- Locks: `worktree/create` locks every worktree it makes (`git worktree
  add --lock --reason "harness: BRANCH"`).  Agents run git in a sandbox
  that shows only their own worktree, where `git worktree prune` takes
  every other worktree for deleted and drops its registration: its files
  stay, without an index, and git fails in them.  Prune never touches a
  locked worktree, and git removes one only when forced twice.  The
  harness's locks are those whose reason starts with `harness: `
  (`harness-worktree-lock-prefix`); other locks are left alone.
  - `worktree/lock` (default reason `harness: BRANCH`; a locked worktree
    keeps its lock) and `worktree/unlock` (lifts only a harness lock,
    unless ANY) resolve to non-nil when they changed something and emit
    `worktree/locked` / `worktree/unlocked` (ROOT PATH).
  - The merge queue unlocks a child's worktree once its branch is
    merged, so merged worktrees can be pruned again; a failed, aborted or
    cancelled merge leaves the lock on.  A merged task that goes back to
    work locks its worktree again.
  - `worktree/remove` lifts a harness lock first, and puts it back when
    git still refuses (local changes).  FORCE is `git worktree remove -f
    -f`, past local changes and any lock.  Task archive and the worktree
    list's `d` go through it.  Before git runs, the async filter
    `worktree/before-remove` (value nil, args ROOT PATH) lets whatever
    runs from the worktree let go of it: the harness repository's
    plugin (tools-dev) stops the Emacs that `open_harness` started
    there.
  - `worktree/prune` runs `git worktree prune -v` outside the sandbox,
    where git sees every worktree, so it prunes only worktrees really
    gone, and skips locked ones as git does.  It returns git's lines plus
    a `Kept ...` line for each locked worktree whose directory is missing
    (`worktree/remove` takes those away).
  - `worktree/prune-merged ROOT &optional DRY-RUN` removes the
    worktrees whose work has already merged -- what keeps the harness's
    own worktrees (`worktree/create` makes one per session) from piling
    up for years.  A worktree is removed when it is not the main or a
    bare one, has not lost its directory and git would not prune it, is
    unlocked (by the harness or anyone else), is clean, is used by no
    session that is still working (an inactive one does not count), and
    has merged: either its HEAD is an ancestor of ROOT's HEAD, or its
    path is in the merged-worktree record.  That record exists because a
    merge lands as one squash commit: the branch tip is then in no
    history, so ancestry cannot say the worktree merged.  The merge
    queue's `merge/finished` event writes the child's worktree to
    merged-worktrees.json in the state directory
    (`harness-worktree--on-merge-finished`), and `worktree/removed`
    takes it out again.  Each worktree is checked and removed through
    `worktree/remove`; a failure is logged and the rest go on.  DRY-RUN
    names what would go and removes nothing (the worktree list's `P`
    asks before removing: `p` stays `worktree/prune`).
  - Worktrees made before locks: `worktree/lock-existing ROOT` locks the
    registered worktrees in the directory the harness puts its worktrees
    in (`harness-worktree-directory-function`, ROOT/.worktrees/ by
    default) that have no lock, whose directory exists, and that the sync
    filter `worktree/lock-existing-p` (value t, args ROOT WORKTREE) does
    not turn down; the tasks module turns down merged tasks' worktrees.
    The main checkout and foreign worktrees are never touched.  A
    repository with many of them is locked a bounded number at a time
    (`harness-worktree--lock-concurrency`, 8), not one git at a time.
    On `harness/started` and `harness/reloaded` it runs for the main
    checkout of every repository the sessions work in, once per
    repository: worktree-locks.json in the state directory lists those
    done, so a merged and unlocked worktree stays unlocked.  The
    worktree list runs it again with `L` (for worktrees registered again
    by hand after a prune), and `l` locks or unlocks the worktree at
    point.
  - The sandbox module's `sandbox/check-command`, through the perms
    module's sandbox guard, refuses `git worktree prune` and touching
    other worktrees in sandboxed commands (see sandbox).
- Nothing re-registers a worktree whose registration was pruned anyway;
  that is a repair by hand, after which `L` locks it.

### merge

One queue serves every merge: a sub-agent's branch into the session
that started it (its working directory, a worktree), a task's branch
into the main checkout, nested at any depth.  What a merge names is a
*target*, not a parent: the session the branch merges into, or -- for a
branch with no session to merge into, a task's -- the main checkout
itself, given as its directory.  Both are keyed, locked, scheduled and
resolved the same way, and both emit the same events, so a task's
session may itself be a target with a queue of its own.

- `merge/enqueue CHILD-SID TARGET &optional :message` → position;
  `merge/queue TARGET`; `merge/view TARGET` (`merge/queue` items then
  the merges TARGET finished recently, newest first, each with `:name`,
  `:reason` and `:finished` -- what the session's chat panel shows);
  `merge/pending SESSION-SID` (the merges into a session that are not
  through yet: queued, merging or in conflict; what it may not hand in
  past, see tools); `merge/status CHILD-SID`; `merge/cancel CHILD-SID`.
  TARGET is a session id or a directory.  When the target is a session
  and it reaches a step boundary (`agent/step` filter) or is idle, the
  head of its queue gets the lock; a main checkout has no session to
  wait for and starts as soon as the lock is free.  Each merge is a
  transaction that never leaves the target's checkout mid-merge.
  `git merge-tree --write-tree` merges the child's branch
  into the target's HEAD off to the side; a clean result becomes ONE
  commit (`git commit-tree`) whose only parent is the target's HEAD --
  a branch lands as a pull request's worth of work, not as the small
  commits its agent made, which are not ancestors of the target
  afterwards.  Its subject is the child session's name and its body
  lists the commits the branch brings (bounded) and their diffstat
  (`harness-merge--message`), so the target's history stays legible
  with so many tasks merging.  The checkout moves onto the commit with
  `git merge --ff-only`, which git refuses, changing nothing, when it
  would overwrite uncommitted or untracked work there or a merge is
  already in progress (the merge fails; a HEAD that moved meanwhile is
  merged again).  A branch whose work the target already holds -- merged
  before, or the same change committed there -- leaves nothing to
  commit: a merge whose tree equals the target's HEAD tree is done
  with, without a commit (`git merge-base --is-ancestor` catches a
  branch that is in history; the tree comparison catches one that was
  squashed in).  Because a squash leaves the branch's commits out of
  the target's history, the merge records the tip it merged in
  `refs/harness/merged/BRANCH` (`harness-merge--record-merged-tip`) and
  computes that branch's next merge from it (`git merge-tree
  --merge-base`): a branch that carries on after it merged -- sent back
  to work, or prompted again -- brings only its new commits instead of
  replaying its own squash commit and conflicting with it.  On conflict the
  target is untouched and the lock passes on at once, and the target's
  commit is to be `git merge`d into the child's branch, in its own
  worktree.  By default (`harness-merge-conflict-resolver` `fresh`) the
  harness starts a fresh `subagent` session for it -- a child of the
  child session, in its worktree, with its settings but a model no
  stronger than the medium tier (`harness-merge-resolver-model`, by
  default nil: the child's model when its provider ranks it medium or
  below (or its tier is unknown), else that provider's medium model,
  else its simple one, else the child's own; thinking no harder than
  the level the provider's medium tier names, else medium;
  `harness-merge--resolver-settings` has the rule; `child` keeps the
  child's model and level, a `PROVIDER:NAME` is that model, at the
  child's level) -- prompted (from
  `harness-sender-system "merge queue"`) with only the files, both
  sides' commits and what to do: a child that waited long in the queue
  would pay for its whole history on a cold prompt cache.  Its turn
  ending without `merge_done` fails the merge (event `merge/resolver
  CHILD PARENT RESOLVER`; `merge/queue` items carry `:resolver`).  The
  child gets a hint naming the resolver and, once the resolver's turn
  starts, a `spawn_agent` call that the merge queue made (`:meta` `:from`
  the merge queue, `:child-id` the resolver; see Node), so it reads as a
  sub-agent the child started.  The call's result comes when the
  resolver stops: its last reply and spawn_agent's footer, a success
  when `merge_done` queued the branch again, else an error saying why
  (the turn ended without it, the prompt failed, or the merge was
  aborted or cancelled, which stops the resolver).  A resolver whose
  turn never starts gets the call and its result together.  Showing
  the call only once the turn has started means a harness stopped
  after that point finds the resolver saved running, and settling it
  answers the call (see session).  With
  `child`, the child session itself gets that as a steering message.  A merged child's worktree loses
  the harness's lock (`worktree/unlock`; see worktree).
- `merge_done` (called by the child or its resolver) checks the child's
  worktree contains the target's commit, merged and committed, and
  queues the branch again.
- Events `merge/queued CHILD TARGET POSITION`, `merge/started`,
  `merge/conflict CHILD TARGET FILES`, `merge/resolver CHILD TARGET
  RESOLVER`, `merge/finished CHILD TARGET STATUS`
  (merged|failed|aborted|cancelled).  TARGET is the target's session id,
  or the main checkout's directory for a root target.
- Nesting: a session's own branch may be queued upward (`merge/enqueue`
  with the child being a session that is itself a target) while the
  merges into it are still to come, but it does not start: the pump
  takes an entry whose child has nothing of its own pending, and when
  that child's queue drains the queue it is itself queued in is pumped
  again (`harness-merge--startable-p`, `harness-merge--finish`), so a
  branch merges on top of the work it was built on.  A session may not
  hand in while `merge/pending` says anything (see tools): the work it
  builds on has to be in its branch first.  A merge that failed does not
  wait there -- the child's work is the child's to fix, and the queue
  told the session with a hint -- and the queue view shows it.
- Moves (`session/move`): a merge goes into the target's cwd as it is
  when the merge starts, so the `session/before-move` filter
  (`harness-merge--before-move`) keeps a session with branches queued to
  merge into it where it is, and a session resolving a merge's
  conflicts, until those merges are through.  A child (in a worktree)
  never moves.  A target that moves before a child queued its branch
  gets that branch merged into its new cwd, which only works when the
  new cwd is a checkout of the same repository: `merge/enqueue` refuses
  a target outside any git repository, and git cannot merge a branch
  another repository does not have.

### commit-msg

A module of its own (lisp/modules/harness-commit-msg.el, `:requires
'(config worktree)`) that installs a `commit-msg` hook taking the lines
that attribute a commit to Claude out of its message, in the
repositories that ask for it.  Opt-in, always: a tool that many
repositories share must not rewrite commit messages unasked -- another
workflow may depend on a co-signing agent's trailer, which the hook
would drop silently -- so nothing is ever installed in a repository
nobody turned it on for.  Modules load by themselves, so a loaded
module does nothing in a repository that did not opt in.  It calls the
worktree module's git helpers (`harness-worktree--git`,
`--same-path-p`, `--known-roots`) and changes nothing there.

- The setting, `harness-commit-msg-strip-attribution`: a boolean
  `defcustom`, nil by default, `:safe #'booleanp` so Emacs reads it from
  a `.dir-locals.el` without asking.  It is in `harness-config-keys`,
  so it layers like `harness-model`: the policy, else a `.dir-locals.el`
  in the session's directory, else the one at the project root, else
  the global (customize) value.  The settings page shows it as *Strip
  Claude attribution* in the Commits section, after Task board; its
  Project scope writes `((nil . ((harness-commit-msg-strip-attribution
  . t))))` to the project's `.dir-locals.el`.  The global value t opts
  every repository the harness works in; the docs recommend turning it
  on per project.
- Which repositories.  The hook lives in a repository's shared hooks
  directory, so it acts on the main checkout and every linked worktree
  alike: the repository is the unit, named by its main checkout MAIN
  (`harness-files-main-root` of a directory, made canonical, with a
  `.git` directory; remote directories are skipped).  It is selected
  (`harness-commit-msg--selected-p MAIN &optional DIRS`) when
  `config/get` of the setting is non-nil at MAIN or at a directory the
  harness works in that lies in that repository: one of
  `harness-config--work-dirs` (the active sessions', the current tasks'
  and their sessions') whose main checkout is MAIN, or one the event at
  hand names (DIRS).  So a `.dir-locals.el` at the root of the main
  checkout opts the project in, and so does one that applies to a
  session working in it: a task worktree's, or one in a subdirectory a
  session works in.  The work directories are looked at only when MAIN
  and DIRS do not select it.
- When it acts.
  - `worktree/created ROOT WORKTREE`: ROOT's repository, with ROOT and
    the new worktree's `:path` as event directories; the hook goes in
    when it is selected.  Nothing may fail `worktree/create`: the
    handler catches and logs.
  - `session/created ID SESSION` (SESSION's `:cwd`) and `session/moved
    ID OLD NEW` (NEW): that directory's repository, with that
    directory; the hook goes in when it is selected.  This covers a
    repository used without worktrees.  Many sessions are made
    (sub-agents, plan workers, BTWs), so the repositories found
    installed since the last full pass are kept in a table
    (`harness-commit-msg--installed`, `pending` while an install runs)
    and skipped: a session there runs no git and reads no setting.
  - `config/changed` of this key (compared by name, `(format "%s"
    key)`): a full pass, with CWD as an event directory when it is
    non-nil.  Turning the setting on or off on the settings page
    therefore takes effect at once.
  - `harness/started` and `harness/reloaded`: a full pass.
  - A `.dir-locals.el` edited by hand gives no event: the next start or
    reload applies it, while worktree and session events see it at once
    when it turns the setting on.
  - A full pass clears the table first, takes as candidates
    `harness-worktree--known-roots`, the repositories of the work
    directories and of the event directory, and the recorded
    repositories, then installs the hook in a selected candidate and
    removes it from a recorded one that is no longer selected.  A
    repository whose setting cannot be read is left as it is.
  - Every handler runs only while the module is ready and logs what it
    signals; the init function also runs at top level, so a hot reload
    subscribes (`harness-on` subscribes a function once).
- The record: commit-msg-hooks.json in the state directory, a JSON
  array of main checkouts, read and written as worktree-locks.json is.
  A repository is recorded whenever its hook is the harness's after an
  install, written by it or already current.  A recorded repository
  that is no longer selected loses the hook in the next full pass, but
  only a file that still carries the marker in the repository's own
  hooks directory (`GIT-COMMON-DIR/hooks`): never anyone else's hook,
  and nothing in a `core.hooksPath` elsewhere.  The harness's file there
  goes even when a `core.hooksPath` set since keeps git from running
  it, since it would run again once that is unset.  Then the repository
  leaves the record, also when its hook was gone already; a recorded
  path that is no repository any more just leaves it.  A failure keeps
  the repository recorded, for the next pass.
- `commit-msg/uninstall DIR` (ACP `_harness/commit-msg/uninstall
  {dir}`) removes the harness-marked hook of DIR's repository, never a
  foreign one, and drops the repository from the record and the table.
  It resolves to `(:repository MAIN :removed BOOL :reason REASON
  :selected BOOL)`: REASON is null when the hook went, else `none` (no
  `commit-msg` hook), `foreign` (somebody else's), `hooks-path` (none
  of the harness's, and `core.hooksPath` puts the hooks elsewhere),
  `remote` or `no-repository`; `:selected` says whether the setting
  still selects the repository, in which case the hook comes back the
  next time the harness installs it.  The UI's
  `harness-commit-msg-uninstall` (lisp/ui/harness-ui-commit-msg.el,
  module `ui-commit-msg`) reads a directory, the current project's root
  by default, calls the method with `harness-ui-call` and says in the
  echo area what happened -- and, when the setting still selects the
  repository, that it has to be turned off for the hook to stay away.
- The hook (`harness-commit-msg--hook`): `#!/bin/sh`, then the marker `# harness: strip Claude attribution
  trailers` (`harness-commit-msg-hook-marker`) on its second line, which
  is how the harness tells its own hook from anyone else's.  It drops
  the lines matching `harness-commit-msg--claude-attribution-regexp`
  with `grep -iE` -- a `Co-Authored-By` or `Signed-off-by` naming
  Claude, a `Generated with` line naming it, a `Claude-Session` line, a
  bare claude.com or claude.ai link -- keeps every other byte of the
  message, trailing newlines included, leaves a message that would be
  empty without its Claude lines as it was, and always exits 0.  It
  goes into the directory `git rev-parse --git-path hooks
  --git-common-dir` resolves, and only when that is the repository's
  own hooks directory: a `core.hooksPath` pointing elsewhere is left
  alone, and so is a `commit-msg` somebody else wrote, byte for byte,
  each logged once per repository.  A harness-marked hook whose text
  changed is rewritten; the file is mode 0755.  Remote (TRAMP) roots
  are skipped, and a failure is logged and never fails anything else.
  Agents working in a linked worktree cannot change it: the sandbox
  mounts the repository's hooks directory read-only there (see
  sandbox).

### priority

A plugin of its own -- a module, not part of tasks or tools-shell --
that owns the one vocabulary everything that queues work by priority
shares: tasks waiting for a project's slots, and the calls of the tools
that start processes waiting for a machine's slots (see tool-slots).

`harness-priority-levels` are the priorities a session may have, lowest
first: low, medium and high; `harness-priority-default` is medium.
`harness-priority-read VALUE` reads one (a symbol or a string in any
case, "med" meaning medium; anything else is refused) and
`harness-priority-level VALUE` reads a stored one (nil, or a name no
level has, is the default), which is what a reader wants:
`harness-priority-rank` gives its place among the levels (0 is low) and
`harness-priority-above-p A B` says whether one is above another.

A priority is the session's -- any session's, a plain chat's as much as a
task's.  It lives in the session's `:ext` under `:priority`, as the
level's name, set with `session/set-ext`, so it is stored with the
record and comes back after a restart.  `harness-priority-ext LEVEL` is
the `:ext` a session is created with (`session/create`),
`harness-priority-set-session ID LEVEL &optional HINT` sets it, and
`harness-priority-session SESSION` / `harness-priority-of SESSION-ID`
read it: a session with none of its own takes its parent's
\(`:parent-id'), up to `harness-priority--parent-depth' levels, so the
sub-agents and forks working for a task work at the task's priority, and
a chain with none is the default.

Methods, reachable over ACP as `_harness/priority/get {sessionId}`,
`.../rank {sessionId}`, `.../set {sessionId, priority}` and
`.../set-all {priority, filter}`.  Every one of them takes a session:
a priority is never a task's, nor a board's, but the session's, so the
input to set or read one is always a session id.

- `priority/get SESSION-ID` -> the priority as "low", "medium" or
  "high"; the session's own, else its parent's, else the default; the
  default too for a session nobody knows.
- `priority/rank SESSION-ID` -> its place among the levels, 0 is low;
  for callers that order something by priority without knowing the
  levels, such as the tool slots.
- `priority/set SESSION-ID PRIORITY` -> the level's name it set;
  PRIORITY is read as `harness-priority-read' reads it, and a name no
  level has is refused (`session/set-ext' signals for a session nobody
  knows).
- `priority/set-all PRIORITY &optional FILTER` -> the ids of the
  sessions that changed, newest first.  The bulk way to give sessions a
  priority, as `task/set-all' is for tasks: FILTER is the one
  `session/select' takes (nil selects every session, `(:active t :tasks
  t)' every current session and the session of every current task of
  every project, `(:ids IDS)' just the sessions named, which is what the
  session list sends for its marked sessions), PRIORITY is read before
  anything changes, and a session already carrying that level of its
  own is left alone.

A task has no priority of its own: a task's priority is its session's,
and every task has that session from the moment it is submitted (see
tasks).  `harness-priority-of-task TASK` reads the session its
`:session' names; a record from before every task had one -- with its
own `:priority' field (`harness-priority-task-key') -- is read once,
for the session it gets, and only by that function;
nothing writes a priority on a task's record any more.
So setting a task's priority is setting its session's (`priority/set',
`harness-priority-set-session'), and `task/set-all''s `:priority' is
handed to each selected task's session; `task/set-priority' and every
other route to a task's own field are gone.  `ui-priority' shows and
sets a session's priority in the chat header, the session list and the
harness keys.

### tasks

Task mode: one session per task.  TASK =
`(:id "t-…" :project ROOT :cwd DIR :prompt "…" :attachments (…) :name "title or nil"
:state pending|refining|active|merging|review|done
:column pending|backlog|needs-input|active|review|merging|done
:backlog BOOL :note "the words a backlog task was written up from" :refined F
:session SID :outcome nil|end-turn|error|cancelled|duplicate|merge-failed|merged|…
:waiting nil|"what the session started runs outside its turn"
:error "…" :duplicate-of ID :main-tree BOOL :worktree DIR :branch NAME :base NAME :merge-status nil|queued|merging|conflict
:merge-queued F :conflicts (FILE…) :merged BOOL :archived BOOL :created F :started F :finished F
:queued-at F :waits ((:at F :seconds F :priority "low|medium|high") ...)
:verified BOOL :verified-at F :feedback ((:text "..." :at F) ...))`.
`:column` is derived on every read: `backlog` for a backlog task or
its write-up -- one the scheduler never starts, for the user's
`task/start` -- `needs-input` when the session is
blocked on a request or the task stopped part way, `merging` while its
branch holds a place in the merge queue (`:merge-status` is queued,
merging or conflict; `:merge-queued` is when it joined, which orders the
board's section), `review` while its finished work waits for the user's
verdict.  The record keeps no priority: a task's priority is its
session's (`harness-priority-of-task'), and a read of a task has one
all the same (`:priority' in `task/get''s and `task/list''s answer, the
board's facts), computed from that session when it is asked for, never
stored.  Every task gets its session at submission
\(`harness-tasks--make-session'): in the task's `:cwd', idle, with the
task's priority in its `:ext' (`harness-priority-ext') and the settings
of what it does next -- a backlog task's write-up settings
\(`harness-tasks--refine-settings'), any other's work settings
\(`harness-tasks--work-settings') -- so a task waiting for a slot
already has the
session its priority lives on.  When the task starts, that session --
the write-up's, for a backlog task -- moves to the worktree, takes the
task's work settings (`harness-tasks--continue-session') and does
the work; nothing waits for the start to make a session.  Only a record
from before this -- one with no `:session' -- is read once for its own
`:priority' field (`harness-priority-task-key'), and gets a session the
way it always did when it starts.  The session's `:ext' `:priority' is
the level the rest of the harness reads, and the queues the session's
work waits in -- the tool slots above all -- are served by it (see
priority).

- `task/submit CWD PROMPT &optional (:attachments :model :permission-mode
  :thinking :non-interactive :supervisor :refine :main-tree :priority)` → task; it
  starts when one of its project's `harness-tasks-max-running` slots is
  free.  Its session is made now, at the task's directory, idle, with
  the task's priority and the settings of its first turn (a backlog
  task's write-up settings) in it, so the task has somewhere to live --
  and the priority has -- from the start; the work goes on in that
  session when it starts, on the task's work settings.  A `:priority`
  is read as
  `harness-priority-read' reads it (medium by default) and given to that
  session (`harness-priority-ext'): it orders the project's waiting
  tasks, and it is what the queues the session's work waits in go by
  (see priority).  The limit is per project: every project (a task's `:project`,
  the main checkout, else its `:cwd`) has that many slots of its own,
  and the scheduler (`harness-tasks--schedule`) starts each project's
  queued tasks in start order (`harness-tasks--start-order`: highest
  `:priority` first; among equals, work sent back from review
  (`:sent-back`), then tasks returned to pending (`:returned`, the first
  returned first), then the rest, oldest first) while that project has
  slots left (`harness-tasks--free-slots PROJECT`), so a project at its
  limit holds up only its own tasks.  The limit (a `natnum`, or nil for
  none; 0 starts nothing by itself) can change while tasks wait: its
  `config/changed` runs the scheduler (`harness-tasks--on-config-changed`),
  so a limit raised from a board's `N at a time` button or the settings
  page starts the waiting tasks it lets through at once, and a lower one
  stops no task at work.  Only top-level sessions take slots
  (`harness-tasks--holds-slot-p`): a task holds one while it starts,
  and while it is `active` with its own session -- one without a
  `:parent-id` -- running or blocked mid-turn, or idle with work it
  left running (`:waiting`, a supervisor's workers say), which it holds
  through that work: such a task can be pre-empted (below), and its work
  stops with it.  A task blocked on the user long enough lends its slot
  instead (lending, below).  The sessions working for
  a task never take one of their own: its sub-agents and forks, and the
  merge queue's conflict resolvers (`subagent` children of its session).
  Nor does the merge queue, which the limit never holds up: a task in it
  (`merging`) holds no slot, even while its own session commits or
  resolves the conflicts, so a waiting task starts meanwhile; nor does
  writing a backlog task up (`refining`).  `:priority` is `low`, `medium`
  (the default; `med` reads as it) or `high`, a symbol or a string in
  any case; anything else is refused before the task is made.  A
  priority orders the queue, and stops a task at work only for work
  sent back from review that outranks it (pre-emption, below); a
  backlog task still waits for `task/start`.  Missing options come from
  `harness-tasks-model`, `-permission-mode` (auto), `-thinking` and
  `-non-interactive` (off), else from what the directory configures, so
  a task is interactive unless `harness-tasks-non-interactive` or the
  directory's `harness-non-interactive` is on; an explicit false turns
  non-interactive off whatever they say.  `:supervisor` is the task's
  own switch of the supervisor module, `t` to plan and delegate or an
  explicit false to work hands-on (`:false` in the record); without it
  the task's session takes `harness-supervisor-tasks` when it starts,
  and without that module it means nothing.  `task/settings` reports the
  values a new task would get, the configured ones included --
  `:supervisor' only while the module is loaded -- and the board submits
  them with each task.
  `:attachments` are files of the harness's machine (`:path`, with
  `:mime`, `:name` and `:size`), as the compose box of the Emacs it runs
  in attaches them, or, for a client on another device, which can name no
  such file, pictures sent as data: `{data, mime, name}`, `data` in
  base64, with no path.  Each picture sent as data is checked: it is
  `image/png`, `image/jpeg`, `image/gif` or `image/webp`, its bytes are
  what the type says (a `mime` that disagrees is refused, and one left
  out is read from them), and it is no larger than
  `harness-tasks--inline-max-bytes` (10 MB), with no more than
  `harness-tasks--inline-max-count` (8) to a request.  A request with
  one that fails is refused whole, before anything is written.  The
  rest are written to `attachments/TASK-ID/NAME` under the state
  directory, a name made of plain characters whatever the client called
  the picture, and the task holds the ordinary file attachment that
  names it (`harness-tasks--keep-inline-attachments`), so what reads a
  task's attachments takes no notice, and no byte rides in the record or
  in every `task/changed`.  `task/update` takes them the same way.  The
  files stay as long as the task's session does, whose transcript names
  them, and go with it (`harness-tasks--forget-attachments`): a task
  cancelled before it started, `task/delete` with its session, a deleted
  session.  `task/settings` says whether a harness takes them, as
  `:inline-attachments`, the media types: an older harness does not say,
  and a client must not offer it pictures, which it would lose.
  With `:refine` the task goes to the backlog instead (below).
  With `:main-tree` it works in the project's main checkout: no worktree
  is made, it gets no branch, and nothing merges when its turn ends, so
  it can touch the checkout itself -- cleaning up uncommitted changes,
  say.  The flag is explicit, never the default; the `task_submit` tool
  offers it as `main_tree` and the board as a worktree switch beside the
  other new-task settings.  A refined (`:refine`) task keeps it for when
  it starts: the session it was submitted with writes it up at the
  task's directory and then stays there rather than moving into a
  worktree.
- Internal jobs and the limit.  The harness's own model calls -- a
  task's title (`naming/title`, and a session's name, `naming/name`
  with `:opening`), a card's recap, the judge of auto mode and of a
  non-interactive session, emacs_eval's judge, the supervisor's, the
  pet's and the insights' calls, a compaction's summary, the board's
  search -- are internal jobs.  They go straight to `provider/complete`:
  none is a turn of an agent, none makes a session or a task of its own,
  and they run with no tools, under the id of the session they are
  about or one of their own (`naming-…`, `SESSION-perms`).  So they
  never take one of a project's slots, never wait for one and are never
  counted by `harness-tasks--free-slots`: they go out whatever the
  limit, a limit of 0 or a board with every slot taken included, and
  the queue's gate on turns (`harness-tasks--before-turn`), which holds
  those of a waiting task's session, never sees them.  The same goes
  for the tool slots, which hold back tool calls only: `tools/execute`
  runs the `permission/decide` chain, a judge's model call among its
  stages, to its end before it runs the handler, where a governed tool
  waits for its slot, so a judge decides while every slot of the
  machine is taken and holds none itself (see tool-slots).
  Non-interactive mode, which lets a judge decide for a user who is
  away, concerns the sessions that could ask the user something; an
  internal job cannot, so there is nothing to switch for it.  What
  holds a title request back is a throttle of its own, not the limit,
  and what retries one that failed is the layers below it, as for any
  model call, not a timer of the tasks module (see Titles).
- Waiting for a slot: a task that joins the queue is stamped
  `:queued-at` -- on submission (its `:created`), `task/queue` from the
  backlog, and every return to pending (by hand, pre-empted, sent back
  and held) -- and `harness-tasks--queued-since` reads it, else
  `:returned`, else `:created` for older records.  When a queued task
  starts (by the scheduler, or by hand with `task/start`), the same
  `harness-tasks--set` that makes it active pushes `(:at STARTED
  :seconds WAITED :priority P)` on its `:waits` (newest first, at most
  20) and clears `:queued-at`; a backlog task started by hand waited for
  no slot and records nothing.  A task submitted while a slot is free is
  queued for the moment the scheduler takes, and records a wait of about
  nothing, so the waits count every start.  `task/slots &optional CWD`
  hands a UI the slots of CWD's project as plain data: `:project`,
  `:limit` (`harness-tasks-max-running`, nil without one), `:suspended`
  (t or `:false`), `:days` (`harness-tasks-slot-wait-days`, 7),
  `:holders` (every task with `harness-tasks--holds-slot-p`, the longest
  at work first: `:id :title :session :priority :state` -- "starting",
  "waiting" on work its session left running, else its session's
  status -- `:since :sent-back`), `:queue` (the queued tasks in
  `harness-tasks--start-order`: `:id :title :priority :since :reason`,
  the return reason as a string or nil) and `:waits` (the `:waits` of
  the project's tasks, archived and done ones too, of the last `:days`
  days, newest first, at most 500: `:id :priority :seconds :at`).  It
  reads the scheduler's own predicates, so a task's sub-agents, forks
  and the merge queue's resolvers are in none of it.
- A task's session also runs on `harness-tasks-context-limit' (384000)
  tokens of context at most, so it compacts earlier than an interactive
  session; nil gives it the whole window.  A refined task's write-up
  session, and a session adopted by `task/adopt', get it too.  A
  provider that compacts on its own side keeps deciding by itself,
  except Claude Code, which is spawned with the limit as
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' (see the claude provider).
- Backlog refinement (once called grooming): a `:refine` task is
  `refining` while the session it was submitted with -- `ask` and
  non-interactive, `harness-tasks-refine-model` and
  `-refine-thinking` (low), read-only through the tasks module's
  `permission/decide` stage at 25, which denies (final) whatever the
  mode and its rules leave undecided in a turn of a write-up, before
  the auto judge could allow it -- writes it up as told by
  `harness-tasks--refine-prompt` (brief, no changes, no questions, a
  self-contained ticket: title line, what and why, what to change, how to
  tell it is done, related tasks, open questions); after
  `harness-tasks--refine-tool-calls`
  (8) tool calls it is steered once to write up with what it has, which
  keeps it brief.  It is told to search the board first -- one `task_list`
  (`include_archived t`, `limit 50`, the task at hand marked
  `(this task)`) -- and to refuse a request the board already has: an
  exact duplicate is neither written up nor added to the backlog, but
  waits for the user.  The refusal is its final reply, first line
  `Duplicate of ID` (`harness-tasks--refusal`, markdown and a trailing
  full stop aside); `--finish-refinement` then sets `:outcome duplicate`,
  `:duplicate-of` the task named when it is on this harness's board
  (`harness-tasks--duplicate-of`: an id, or a unique id prefix, of the
  task's project, never the task itself) and `:error` the message after
  the first line, shown to the user.  `task/refine ID` with no TEXT
  writes a refused task up all the same, sending
  `harness-tasks--refine-anyway-text`; with TEXT -- or with
  `task/prompt`, like any feedback -- the write-up is done again with
  it.  A write-up also names the related tasks in the same code area in a
  "Related tasks" section -- id, title, branch, session, where each
  stands and what it changes -- and tells whoever does the task to
  coordinate with them rather than redo their work: check where they
  stand, message their sessions, cherry-pick their commits (see also
  `harness-tasks--start-message`).  Otherwise its final reply becomes
  `:prompt` (the original stays in `:note`) and the task waits in
  `pending` with `:backlog t`, whose column is the backlog, apart from
  the queued pending tasks: the scheduler never starts it, only
  `task/start`, so the backlog survives restarts; `task/queue` (the
  board's [Queue it]) puts it back in that queue, the write-up kept.
  Who does that is the project's backlog mode: the user in `manual`
  mode, the default, and in `auto` mode the write-up's own end.
  `--finish-refinement` then hands the task to
  `harness-tasks--auto-queue`, which calls `task/queue` soon after
  (`harness-run-soon`: out of the turn's end, as `task/queue` may start
  the task) unless by then the task left the backlog, was archived, has a
  turn of its session running or a message queued in it -- feedback for
  the write-up, whose own end queues the task instead.  Only a clean end
  queues: a write-up that fails, stops or refuses the task as a duplicate
  waits for the user as ever, and one done again -- feedback,
  `task/refine` after a failure, writing a duplicate up anyway -- queues
  it.  A hand edit (`task/update`) is no write-up and queues nothing,
  and switching modes moves no task.  From the write-up's end until the
  task is queued its id is in `harness-tasks--joining` and its view has
  `:joining-queue t`, so that a `task_wait` does not settle on it as a
  backlog task: it waits on for the work.  `task/backlog-mode &optional
  CWD` returns `(:project ROOT :mode MODE)`, `task/set-backlog-mode MODE
  &optional CWD` (`manual` or `auto`, a symbol or a string) and
  `task/toggle-backlog-mode &optional CWD` switch it; `task/settings`
  has it as `:backlog-mode`, and a task's view has `:auto-queue t` while
  its project's backlog is in auto mode.  The projects in auto mode are
  kept, like the suspended queues, in `task-auto-queue.json` in the
  state directory: a JSON array of project roots.  A turn of a backlog
  task's session before it starts is feedback (`task/prompt`) and
  rewrites the write-up; a write-up that stops needs input (restarts:
  below).  `task/refine ID &optional TEXT` refines a queued task or
  writes one up again.  Starting continues the same session: in git it
  moves into the task's new worktree (`session/update :cwd :worktree`),
  its provider conversation is dropped (the Claude CLI keeps
  conversations per directory; the new one gets the transcript, the
  write-up's conversation, as text: see "Replay") and it is prompted with
  `harness-tasks--start-message`, the write-up and the quoted note, under the
  task's own settings.  Dropping a task that never started -- a backlog
  one, or one waiting for a slot -- deletes its session with it: that
  session holds the task's priority and nothing else, and the write-up's
  transcript goes with the task it was written up for.
  The messages task mode composes itself (starting a written-up task,
  the restart resume, the nudge to finish a write-up) are marked as
  from `harness-sender-system "tasks"`; the task's prompt and
  `task/reject` feedback are the user's, and so is a `task/prompt`
  follow-up unless its OPTS `:from` names another sender:
  `task_control`'s message names the calling session.
- Plan mode: a `:plan` task (`task/submit`'s `:plan`, which implies
  `:refine`; the board's Plan mode; `task_submit`'s `plan`) is a backlog
  task whose write-up is a plan for a cheaper model: supervisor mode's
  idea without its workers, and beside it, as the supervisor module
  leaves a planned task's work hands-on unless the task has a setting
  of its own (`harness-supervisor--task-value`).  Its session plans on
  `:refine-model`/`:refine-thinking` when given, else on the hard tier
  of the task model's provider (`harness-tasks--plan-tier`, Opus for
  Claude; the task model where the provider names none), and the work
  gets the medium tier (`harness-tasks--plan-work-tier`, Sonnet) as
  `:model`/`:thinking` unless those were given.  The tiers are internal
  defaults, not options: the models are parameters of each task, which
  the board sets per step (docs/configuration-audit.md).
  `task/settings` resolves them for the board as `:plan-model`,
  `:plan-thinking`, `:plan-work-model` and `:plan-work-thinking`, next
  to `:refine-model` and `:refine-thinking`.  The session gets
  `harness-tasks--plan-prompt` in place of the tools agent's planning
  section (`harness-readonly-system-prompt`), and only reads: the
  tasks module registers its sessions with the readonly module
  (`harness-tasks--readonly-policy`: the reading tools, read-only and
  offline bash where the sandbox confines it, `submit_task_plan` and
  `todo_write`, no `web_fetch`), and the write-up gate at 25 denies
  the rest with `harness-tasks--plan-hint`.  `agent/tools` at 50
  offers `submit_task_plan` to planning sessions alone.  After
  `harness-tasks--plan-tool-calls` (40) tool calls, and every half
  budget after (`harness-readonly-budget-point-p`), it is steered to
  hand the plan in with what it knows, unless that call was the hand-in
  itself.  `submit_task_plan TITLE PLAN`
  (tools-sessions, kind meta) calls `task/hand-in-plan SESSION-ID TITLE
  PLAN`, which puts `TITLE\n\nPLAN` in `:prompt`, keeps the task
  pending in the backlog with `:refined` set, gives the session the plan
  (`session/set-plan`, and a `plan` node in its transcript) and adds a
  hint; the tool ends the turn (`:end-turn t`), and
  `--finish-refinement` keeps the plan rather than taking the final
  reply for the write-up.  A planning turn that ends with neither a plan
  nor a duplicate refusal is sent back by the `agent/stop` filter
  (`harness-tasks--plan-stop`) with `harness-tasks--plan-reminder`, at
  most `harness-tasks--plan-max-reminders` (2) times.  Feedback to the
  planning session (`task/prompt`, `task/refine`) asks for the whole
  plan again.  Starting the task opens its message with
  `harness-tasks--plan-start-message`, telling the medium model to keep
  to the plan's decisions and say where it had to depart from them.
- `task/adoptable &optional CWD` lists the project's open sessions that
  are not tasks; `task/adopt SESSION-ID` makes one a task (its first
  message is the prompt; a worktree session keeps its worktree and merges
  like any task; an idle one waits in `needs-input` with `:outcome adopted`).
- Starting: in a git project (`harness-tasks-worktrees`) `worktree/create`
  on branch `harness-tasks-branch-prefix` + slug + id, then the task's
  session -- the one it has had since submission -- moves into that
  worktree (`session/update :cwd :worktree`, `harness-tasks--continue-session')
  and is prompted with the task, on the settings the work runs with
  (`harness-tasks-permission-mode`, interactive by default); a
  system-prompt section tells it to commit on its branch and not merge.
  Outside git the session runs in CWD.  A `:main-tree` task skips the
  worktree: its session runs at the project's main root, and the system
  prompt says the work takes effect there, with no branch to make and
  nothing to merge.  The worktree stays locked until its branch is
  merged; a follow-up to a merged task locks it again (see worktree).
  Only a record from before every task had a session is opened here
  (`harness-tasks--open-session': a session made in the task's
  directory, then prompted).
- Titles: a task is named as soon as it is submitted, while it may wait
  for a slot: `task/submit` sends its prompt (a backlog task's `:note`)
  to `naming/title` with `:task ID` and the model its session will have,
  and `naming/system-prompt` adds `harness-tasks--naming-instructions`
  (nil for none), so the model titles it like a ticket.  The title
  becomes the task's `:name`; the board, `task_list`, the session list,
  search, notifications and insights show the session's name, else the
  task's `:name`, else the prompt's first line.  The session the task
  was submitted with is made before the request goes out, taking
  `:name` when the task has a title by then (`harness-tasks--name-option'),
  so a title that comes later names it through `session/update`
  (`harness-tasks--named'); a task's session is never named again as its
  turn starts.  While
  the request is out, the `naming/auto-p` filter keeps a session of the
  task from being named as its turn starts, and the title names it when
  it comes.  Nothing waits for a title: a failed request (or one that
  times out) leaves the task untitled, and a nameless session of it
  whose turn runs is then named from its first message (`naming/name`
  with `:opening`).  The request is an internal job (see "Internal jobs
  and the limit" above): it takes no slot of the project and waits for
  none, so a task that waits for one, behind a full board or a limit of
  0, is titled all the same.
  A title is not asked for again by task mode.  The request is an
  ordinary `provider/complete` request, so the layers below retry it as
  they do any model call: the HTTP layer (`harness-http-request`, which
  the OpenAI-compatible providers, DeepSeek among them, and Bedrock ask
  to repeat a request whose connection was lost before any of the
  answer arrived) and the Claude Code CLI for its own API calls.  A
  title that still fails leaves a task that waits for a slot untitled
  until its turn names its session, or the harness starts or reloads
  (`harness-tasks--name-untitled`); no timer of the tasks module asks
  again.  That includes a refusal an OpenAI-compatible server answered
  to the streamed completion (an overloaded model's 429 or 5xx, say):
  the HTTP layer repeats a response only when it did not stream its
  body, while Bedrock repeats a throttled or failed one itself
  (`harness-bedrock--maybe-retry`).
  At most `harness-tasks--naming-concurrency` (2) requests are out at
  once, the rest waiting: a pool of the slots library
  (`harness-tasks--naming-pool`, see slots), a throttle of the title
  requests alone, so that a burst of submissions or a board of untitled
  tasks found at start-up does not start a Claude Code process for
  each.  The waiting ones go by their task's priority
  (`harness-tasks--naming-rank`: `harness-priority-of-task`, read again
  whenever a slot frees, so a priority given while a request waits
  counts), the highest first and the oldest first among equals, as the
  board orders its tasks; a task whose request waits or is out is not
  queued twice.  A request holds its slot from the moment it goes out
  until `harness-tasks--named` has taken its answer or its failure.
  When a slot comes to a request whose task started meanwhile (its turn
  names its session) or is gone, it goes back at once and nothing is
  sent.  The throttle has nothing to do with the project's slots
  (`harness-tasks-max-running`): a request neither takes one nor waits
  for one.  `task/update` clears `:name` and asks again when the text
  named from changed; a title of an older prompt is dropped.  Tasks
  found without a title (from before, or whose naming failed) are named
  at start-up (`harness-tasks--pick-up`) and on reload.
- With nothing to review (below), a turn ending `end-turn` queues
  `merge/enqueue SID TARGET`, TARGET being the project root itself: the
  main checkout, which the merge queue takes as a target with no session
  behind it (`merge/enqueue` accepts a directory); `merge/finished …
  merged` makes the task `done`.
  While its branch holds a place in the queue the task is in the
  `merging` column (`:merge-queued` says when it joined).
  Failures the agent can fix (uncommitted work) are steered by the merge
  queue; others, or more than `harness-tasks--merge-attempts`, set
  `:outcome merge-failed`.  Outside git, and in the main tree
  (`:main-tree`), `end-turn` makes it `done`.
- Outstanding work.  A turn ending `end-turn` is not the end of the work
  while something the session started still runs outside it, a
  supervisor plan's workers say.  The tasks module asks `agent/outstanding
  SESSION-ID` (see agent; `harness-tasks--outstanding`) and, when it
  answers a text, leaves the task `active` with the text as its
  `:waiting`: it goes neither to `review` nor to the merge queue.  A
  change of `:state` ends the wait (`harness-tasks--set` drops
  `:waiting` unless the same change sets it), and the turn the session
  takes when that work reports back, or any turn that ends with nothing
  outstanding, ends the task as above.  Only a clean `end-turn` is asked.
  A task waiting on such work still holds its slot (`harness-tasks--holds-slot-p`),
  so it counts as at work: work sent back from review can pre-empt it, and
  a return to pending frees its slot.  Both stop that work, below.
- Review (`harness-tasks-require-verification`, default t): finished
  work is not done until the user has looked at it.  A turn ending
  `end-turn` puts the task in `review` instead, and emits `task/review
  TASK`; in git, when it works on a branch, that branch waits unmerged,
  so nothing reaches the base branch unreviewed.  `task/verify ID` accepts the work (`:verified t
  :verified-at F`): its branch goes through the merge queue as above
  and the task is `done` once merged, waiting in `merging` between the
  two (outside git, or when the branch merged already, at once).
  `task/reject ID FEEDBACK &optional
  ATTACHMENTS` sends it back: the feedback (words, attachments or both)
  goes to the same session, in its own worktree and with its provider
  conversation, as a prompt opened by `harness-tasks--reject-message`;
  the task is `active` again and returns to `review` when that turn
  ends.  Each round is appended to `:feedback`.  Any other message the
  user sends the session while its task waits for review sends it back
  the same way, with the message as the feedback: typed in its chat,
  `task/prompt` from the board, another ACP client, its queue going out
  once the turn ended.  The tasks module's `agent/message` filter
  (`harness-tasks--on-message`) makes the task active at once, keeps
  the round and opens the message with the reject text.  Only the user
  reviews: the harness's own messages (`:from` system) are left alone,
  and a message from another session's agent (`:from` session:
  `session_send`, `task_control` message) is no review either.  It
  keeps no round, its sender stays, and it opens with
  `harness-tasks--aside-message` instead (another session sent it while
  the task waited for review; the work goes back to review when the
  turn ends; hand it in again if it changed, else the report stands).
  The filter makes the task active at once (`harness-tasks--aside`), so
  the turn starts no round (no `:reopened`) and the round's report,
  handed in or recorded missing, stands unless a new one is handed in;
  the task waits for review again when the turn ends.  Any other new
  turn of work (a follow-up, a message from the chat) clears the
  verification, so it is reviewed again; the merge
  queue's own steering (commit first) does not.  Only clean ends go to
  review: a turn that stops needs input as before, and `task/complete`
  (Mark done) counts as accepting the work.  A merge that finishes for
  work nobody verified (one queued before the option was turned on)
  puts the task in review, merged.  `task/archive` works in review too;
  `task/archive-done` leaves those tasks alone.  With the option nil a
  task is done once merged, or outside git once its turn ends.
  `task/settings` reports the option as `:require-verification` (t, or
  false rather than nil), and a board's `V` turns it off and on with
  `config/set`, globally and saved, as the settings page does; tasks
  already in review wait on until verified.
- Additions to the feedback: a message that sends a task back --
  `task/reject`, or any message the user sends its session while it
  waits for review (`harness-tasks--on-message`) -- first asks the
  functions of `harness-tasks-feedback-additions-functions` what to add
  (`harness-tasks--feedback-additions`).  Each is called with the task
  and the words the message says (a string, empty for none) and returns
  nil or `(TEXT . DONE)`: TEXT, a string or nil, goes after the words as
  paragraphs of their own, in the round kept in `:feedback` and in the
  prompt, and DONE, a function of no arguments, is called once the task
  is sent back, or its feedback kept for a slot
  (`harness-tasks--commit-additions`) -- never before, as the message
  may turn out to be refused.  A function that signals adds nothing (it
  is logged).  What they add counts as feedback: `task/reject` with an
  empty message and an addition is a send-back, and with nothing at all
  still an error.  The `patch-review` module uses it to send the drafts
  of the user's review along (see its contract); the tasks module
  knows nothing of reviews.
- Pre-emption: work sent back from review keeps to
  `harness-tasks-max-running`, though its slot may have gone to another
  task while it waited for review.  `harness-tasks--make-room` finds it
  one: a free slot, else the slot of a task at work it outranks
  (`harness-tasks--outranks-p`: a lower priority, or its own priority
  when that task is not work sent back itself, `:sent-back` being when
  it was).  Of those, `harness-tasks--victim` takes the lowest priority,
  then work that is not feedback, then the one at work since last;
  another project's task, and any task while the limit is 0, give none
  up.  A task waiting on work its session left running (`:waiting`, a
  supervisor's workers say) holds its slot through that work, so it is a
  candidate like any other (`harness-tasks--preemptible-p` is
  `harness-tasks--holds-slot-p`).  The
  victim is pre-empted (`harness-tasks--preempt`): returned to pending
  with `:return-reason` `preempted` and `:preempted-by` the task sent
  back, its turn stopped, and a hint in its session once the turn has
  ended ("Pre-empted by task T (TITLE), sent back from review; waiting
  for a slot").  The work its session left running
  outside its turn stops too (next bullet).  A task still starting (its
  worktree being made) is pre-empted the same way: its start launches
  nothing (`harness-tasks--start-current-p`), and its next start reuses
  the worktree being made (`harness-tasks--worktree-promise`).  When a
  slot frees, it carries on in its session, prompted with
  `harness-tasks--preempted-message`, as a task returned to pending is
  with `harness-tasks--paused-message`; both say that workers and
  sub-agents still running were stopped, and that what they were on is
  reported above.  With no task it outranks, or
  its queue suspended, the task sent back waits instead
  (`harness-tasks--hold-back`): pending, `:return-reason` `sent-back`,
  its round kept in `:feedback` and the reject text queued (`:queued`)
  for its start, which opens with `harness-tasks--sent-back-message`.
  It leads its priority in the queue (`harness-tasks--start-order`), and
  while its queue runs the scheduler lets it pre-empt as soon as it
  outranks a task at work: its priority raised, or that task's lowered
  (`harness-tasks--on-priority-changed` runs a pass).  No other waiting
  task pre-empts.  `task/reject` returns the task, active or pending,
  for the client to say which; `task/prompt` to a task waiting that way
  queues its message.  Feedback typed in the chat of a task in review
  sends it back too: with no slot to take, the message is recorded but
  its turn refused by the tasks module's `agent/before-turn` filter
  (`harness-tasks--before-turn`, "Turn not started: task T is waiting
  for a slot ..."), and the message reaches the model with the turn
  that starts the task.  That filter refuses the turn of any other
  sender (another session's agent, the harness) to a task returned to
  pending, pre-empted or sent back while it waits; the user's own
  message to a returned or pre-empted task starts it, as `task/start`
  would.  A task that never started is left alone.
- Lending a blocked task's slot: a task whose own session has been
  `blocked` on the user (a question or a permission request) for
  `harness-tasks-lend-blocked-slot-after` seconds (300; nil never lends,
  and nothing lends without a limit or at 0) holds no slot
  (`harness-tasks--lending-p`, which `harness-tasks--holds-slot-p`
  asks), so the scheduler fills the slot by priority.  How long it has
  waited is from the `session/status` that blocked it
  (`harness-tasks--blocked-at`, else its oldest pending request's
  `:created`), and a timer (`harness-tasks--arm-lend-timer`) runs the
  scheduler when the wait is over, with no other event.  A task waiting
  on work it left running (`:waiting`, or `agent/outstanding` mid-turn)
  keeps its slot, and so does one working in a borrowed slot: loans do
  not nest.  The task the harness starts in a lent slot -- the queue's
  start, or work sent back from review (`harness-tasks--make-room`) --
  records it (`harness-tasks--note-borrow`): `:borrowed-from` is the
  lender (`harness-tasks--lender-for`: the slot is lent when the
  project's tasks in slots of their own and its lenders fill its
  limit).  An explicit `task/start` borrows nothing, as it ignores the
  limit.  When the lender's session stops being blocked,
  `harness-tasks--reclaim` runs soon after (so a turn cancelled with its
  question is over first): if the lender is back at work
  (`harness-tasks--back-p`: not blocked, a turn running or the task
  starting) and its project is over the limit, its borrower is
  pre-empted the way work sent back pre-empts (`harness-tasks--preempt`
  with `:return-reason` `reclaimed` and `:preempted-by` the lender):
  back at the front of the queue, its turn and outstanding work
  stopped, session, branch and worktree kept, a hint saying why, and
  `harness-tasks--reclaimed-message` when it starts again.  A borrower
  that finished, or a lender that stopped lending another way (its turn
  cancelled, the wait or the limit changed, gone), stops nothing: the
  loan just ends (`harness-tasks--tidy-loans`, at each scheduling
  pass).  The board shows `borrowed slot` and `slot lent` on the two
  cards.
- Stopping the work left running.  A task that goes back to the queue
  after its work began -- pre-empted (`harness-tasks--preempt`), or
  returned to pending by hand (`task/return-to-pending`) -- has nothing
  at work, so what its session started that goes on without its turn
  stops with it (`harness-tasks--stop-outstanding`): the tasks module
  asks `agent/stop-outstanding SESSION-ID REASON` (see agent), REASON
  being "its task was pre-empted by task T (TITLE), sent back from
  review", "task T (TITLE) took back the slot its task borrowed" or
  "its task was paused".  It asks once no
  turn of the session runs: at once when none did, which is the case of
  a task that only waited on its workers (`:waiting`), else when the
  turn the pre-emption or the return stopped has ended
  (`harness-tasks--returning` says it is being stopped;
  `harness-tasks--on-turn-ended`).  What the stopped work reports then
  reaches a session with no turn to steer, rather than steering the turn
  being cancelled and getting lost.  A task started again before that
  turn ended keeps its work, and nothing is stopped.  What was stopped is
  a hint in the session ("Stopped while the task waits for a slot:
  Supervisor plan: 2 steps interrupted"); a handler that fails is logged
  and stops nothing else.  The reports of the stopped work -- one message
  for all the interrupted steps of a supervisor's plans, one for each
  sub-agent cancelled, from the harness's `supervisor` and `sub-agent`
  senders -- reach the session while its task waits: the tasks module's
  `agent/before-turn` filter refuses the turn each would start, so they
  stay in the transcript, and the scheduling pass the end of a refused
  turn asks for leaves the task out, as the return itself does, so
  nothing starts it again but a free slot reaching it in line,
  `task/resume-queue` or an explicit `task/start`.  The turn that
  starts it reads them before the opening message, and nothing of the
  stopped work restarts by itself: its session retries the step
  (`retry_step`) or plans again.  A task returned by hand that only
  waited on its workers has them stopped at once, as one pre-empted
  does.
- A turn starting in a task's session makes the task active again, so a
  message sent from a done task's chat buffer reopens it; an archived task
  comes back to the board.
- A task's session does not move to another directory (`session/move`):
  the `session/before-move` filter `harness-tasks--before-move` refuses,
  since the board files the task under its project and follows its work
  in its directory.  A task for the other directory is submitted there.
- `task/list &optional CWD`, `task/get ID`, `task/settings &optional CWD`
  (what new tasks start with, and `:max-running`, the limit, nil for
  none), `task/slots &optional CWD` (the slots, above),
  `task/queue-order &optional CWD` (the queued tasks of CWD's project,
  every project's without CWD, in `harness-tasks--start-order`, each
  `(:id :project :place)`: `:place` is its place in its project's line,
  1 for the next to start, counted per project as the slots are; the
  task_list tool says `#N in line` from it and lists the pending column
  alone in its order), `task/start ID` (ignores the limit; not while a
  write-up runs),
  `task/queue ID` (a backlog task back in the pending queue, where the
  scheduler starts it as slots free; the suspended queue holds it there),
  `task/return-to-pending ID` (a task at work, not one still starting:
  its turn is stopped as `task/cancel` stops one, and the task goes back
  to `pending` at the front of its priority's queue -- ahead of the tasks
  that never started, the first returned first -- with its session,
  branch and worktree kept and `:return-reason` `returned`; the work its
  session left running outside its turn stops with it, once no turn of
  the session runs, see "Stopping the work left running" above.  Its slot
  is free for the others, and the return starts nothing itself, the
  queue suspended or not: it waits for the next task the queue starts,
  `task/resume-queue` or an explicit `task/start`, and carries on in its
  session, prompted with `harness-tasks--paused-message`),
  `task/update ID PROMPT` (not started only; writes a stopped write-up by
  hand; a task named from its prompt is named again), `task/set-all SETTINGS &optional FILTER` (apply `:model',
  `:thinking', `:permission-mode', `:non-interactive' and `:supervisor',
  with an explicit false for the last two meaning off, to every task
  FILTER selects and, when started, its session, and `:priority' to the
  session of each: a task has no priority of its own
  (`harness-priority-set-session'), so a task already at that level --
  its session's, read through `harness-priority-of-task' -- is left
  alone, and the priority is read and refused before any task changes;
  only the settings given change, so without `:priority' (or
  with null) every task keeps its own; FILTER is `:columns'
  (default `harness-tasks-bulk-columns': running, pending, backlog and
  blocked),
  `:ids' (task ids, which the session list sends for the tasks its marked
  sessions work on), `:except' and `:cwd' (without it, every project),
  and review, done and archived tasks are never touched; a task already
  set so is skipped, non-interactive counting as what the task would
  start with
  (`harness-tasks--non-interactive-p`: its own setting, else
  `harness-tasks-non-interactive`, else its directory's
  `harness-non-interactive`), and its session is sent only the
  settings it lacks, so one `session/set-all` changed first gets no
  second hint; a `:supervisor' is the session's `:ext' switch rather
  than a `session/update' setting, so it is applied with
  `supervisor/set' when the module is loaded
  (`harness-tasks--apply-supervisor'), and a backlog write-up's session
  is skipped, its setting waiting for the work; this is the reach of the
  session list's setting commands on marked sessions into their tasks,
  and of the all-sessions commands' and `set_non_interactive`'s),
  `task/session-ids &optional FILTER` (the sessions of the tasks FILTER
  selects, whatever their status; `session/select`'s `:tasks` adds
  those of the current tasks and subtracts those of the done column's
  with `:columns '("done")`),
  `task/prompt ID TEXT &optional ATTACHMENTS OPTS` (follow-up or
  steering; reopens; OPTS `:from` is the sender, as `agent/prompt` takes it; in review the
  user's sends the task back and another session's does not, as above), `task/refine ID &optional TEXT`,
  `task/merge ID` (retry; not in review), `task/retry ID` (have a task
  that stopped carry on where it stopped: a failed merge is queued
  again, a stopped write-up is written again, a pending task starts, a
  stopped turn is prompted with `harness-tasks--retry-prompt` from
  `harness-sender-system "tasks"`, and a task whose work never began is
  started over; it refuses a task that is working, blocked on a
  question, in review or done), `task/verify ID`,
  `task/reject ID FEEDBACK &optional ATTACHMENTS` (both in review only),
  `task/complete ID` (counts as verified), `task/archive ID &optional
  RESTORE` (deactivates the session; removes a merged task's worktree and
  branch), `task/archive-done &optional CWD`, `task/cancel ID` (drops a
  task that has not started, stops a running turn or write-up),
  `task/delete ID &optional DELETE-SESSION` (keeps the worktree),
  `task/for-session SESSION-ID` (the task of a session, or nil, which
  `hand_in` and the session's review banner use; the banner at the end
  of a report popout has the task already) and
  `task/hand-in ID REPORT` (record `:summary` and `:evidence` as the
  work ID handed in; the write-up tool's `:end-turn` ends its turn, which
  the review step then picks up).  A round of work whose turn ends
  without a hand-in -- the model replied instead, or had no tools to
  call -- gets a `:report` marked `:missing t` instead
  (`harness-tasks--missing-report`): no evidence, and as `:summary` the
  session's last message of the round.  A round starts at `:started`,
  at each round of `:feedback`, and at `:reopened` (new work on a task
  in review or done); a report handed in before the round started
  speaks for earlier work, so a round that ends without a hand-in of
  its own replaces it.  A turn on another session's message while the
  task waited for review starts no round, so it keeps the round's
  report, a missing one too (`harness-tasks--missing-recorded-p`):
  the reply it ends with is to that session.  The board's button for
  a missing report reads [No report], its popout says "Not handed
  in", and the session's review banner says so in a line.
- Events `task/changed TASK`, `task/deleted ID`, `task/review TASK` (its
  work waits for the user's review), `task/done TASK HOW` (it became
  done; HOW is `merged` when the merge queue merged its branch,
  `finished` when its turn ended with nothing to merge or review,
  `verified` when the user verified it with nothing left to merge, or
  `completed` when it was marked done by hand, `task/complete`; a task
  already done emits nothing), `task/queue PROJECT SUSPENDED` (its
  pending queue was suspended or resumed) and `task/backlog-mode PROJECT
  MODE` (its backlog mode switched, to `manual` or `auto`), both
  forwarded to ACP clients so every board follows.  Records are written
  shortly after a change and on exit (`harness-tasks-flush`), each into
  its project's store; a store whose text would not change is skipped.
- `task/redact SECRETS &optional PROJECT DRY-RUN` takes secrets out of
  every string of every task record -- the prompt, the report with its
  evidence, the rounds of feedback, errors, the recap -- and out of
  `tasks.json.bak`, the copy of the global store that no save writes
  again; see redact for what it answers.  It is the task module's store
  of the redaction engine.
- Stores: a git project's records go to `harness/tasks.json` in the
  repository's common git directory (`harness-files-git-common-dir`,
  read from `.git` and `commondir` files, no git process):
  `.git/harness/tasks.json` of the main checkout, the same file from
  every worktree and out of every working tree, so `git status`, commits,
  merges and the merge queue never see it.  It is
  `{"state-directory": DIR, "tasks": [...]}`, DIR being the state
  directory of the harness it belongs to, which holds the tasks'
  sessions: a harness with another state directory that still exists
  leaves it alone and keeps its tasks of that repository in its own
  state directory; one whose owner is gone takes it over.  Other
  projects' records, and every record with
  `harness-tasks-store-in-repository` nil, are a JSON array in
  `tasks.json` in the state directory.  `task-stores.json` there lists
  the repository stores, which a start reads before `tasks.json` (a
  repository copy wins), and `task/list CWD` reads its project's store if
  the list missed it.  Each save puts every record where its project
  keeps it, so records move by themselves: the first save after an
  upgrade (or after an in-place reload) moves git projects' tasks out of
  `tasks.json` into their repositories, copying it to `tasks.json.bak`
  first, and turning the option off brings them back.  A repository
  store left without records is deleted; one that cannot be written
  leaves its records in `tasks.json`.
- Restarts: when the module starts, an active task without an outcome
  that nothing in this process works on was interrupted.  Without a
  session it starts over (as pending, or in its worktree when it has
  one); otherwise, with `harness-tasks-resume-interrupted` (default t),
  its session is resumed and sent `harness-tasks--resume-prompt` (the task
  itself when it never got it), past the concurrency limit since it held
  a slot before; with nil it waits in needs-input with `:outcome
  interrupted`.  A backlog task cut short before its session got the
  work starts again (with nil: back to the backlog), keeping a worktree
  it got; a write-up cut short is written again by its session (with
  nil: `:outcome interrupted`).  Merges in flight are queued again, and
  tasks in review wait on for the user.

### session-search

One search over the transcripts of every session
(lisp/modules/harness-session-search.el), for the `session_search` tool,
the harness's search in words (tasks-search, below: the quick search and
the task board's) and the UI's `harness-search-sessions` (C-c h g;
lisp/ui/harness-ui-search.el).

- The transcripts stay in their node logs.  The index is a cache of
  them in SQLite, `search.db` beside `usage.db` (`store/sqlite
  "search"`): a row per node with its readable text
  (`harness-session-search-node-text`: a message's text, a call's tool
  and input, a result's output, a plan's entries…), an FTS5 table over
  the rows (`porter unicode61 remove_diacritics 2`, kept in step by
  triggers), and per log the byte offset read up to.  It is a database
  of its own because it grows about as large as the logs, while
  `usage.db` is small and holds what nothing rebuilds.  Deleting it
  loses nothing.
- Keeping it current: only the complete lines a log gained since its
  offset are read.  An update line (a streamed reply's final text, a
  changed `:meta`) is merged into its node's row, so a reply is
  searchable in full; grep over the logs saw only what one line holds.
  `session/node-added`, `session/node-updated` (not the transient ones)
  and `session/forked` schedule a catch-up a second later; a search
  catches up first with the logs it covers when little is left (else it
  falls back, below); logs never read are read in the background, newest
  session first, in slices of `harness-session-search--slice` seconds
  `harness-session-search--gap` apart (`run-at-time`, starting
  `harness-session-search--start-delay` after the module), and
  `session/deleted` drops a session's rows there too.
- `session/search QUERY &optional OPTS` → promise of `(:query :mode
  :engine :note :loose :total :sessions)`.  OPTS: `:mode` (`text`, the
  default, `literal`, `regexp`, `semantic`; a symbol or its name),
  `:sessions` (ids, all by default), `:exclude` (ids), `:project` (a
  directory: that project's sessions, its worktrees included), `:kinds`
  (node kinds), `:max-sessions` (20), `:max-matches` (3).  `:engine` says
  what searched: `fts`, `vectors`, `hybrid` (both), `grep`, or `none`
  when no session was to be searched; `:note` why a text search fell
  back; `:loose` that no session has every word and these have some;
  `:total` how many sessions match.  Each session is `(:id :name
  :updated :status :kind :cwd :project :name-match :matches :score
  :hits)`, each hit `(:node :kind :tool :ts :from :from-text :snippet
  :ranges :score)`, `:ranges` the matches in the snippet as `(START
  END)`.
  - `text`: every word must match, in any form (porter stemming; case
    and accents ignored); `"a phrase"`, `prefix*`, `OR` and `-word`
    work, and each term goes to FTS5 quoted, so nothing else in a query
    is read as FTS5 syntax.
    Sessions rank by their best node (BM25), fused by reciprocal rank
    fusion with the sessions whose name has the words and, with
    vectors, with how near they are in meaning.  When no session has
    every word, those with some come back (`:loose`); when none has
    any and there are vectors, the sessions nearly as near in meaning
    as the nearest (`harness-session-search--near-share`), with a note.
  - `literal` and `regexp`: grep
    (`harness-session-search--grep-program`) over the logs,
    case-insensitively, newest session first; an extended regexp is
    translated for Emacs to check the node's final text, so a node
    matches on the text it ends with, update lines and all.
  - `semantic`: the nearest in meaning, by the vectors.
  - Without SQLite or FTS5, with `harness-session-search-index` nil, or
    with more of the logs it covers still to index than a search reads
    first (`harness-session-search--catch-up-bytes`, 4 MB), text search
    greps for the text as typed, and `:note` says why.
- Embeddings, off unless `harness-session-search-embedding-model` names
  a model whose provider embeds (`provider/embed`), with
  `harness-session-search-embedding-dimensions` for shorter vectors.
  User messages, replies, plans and compaction summaries are cut into
  chunks, embedded in batches in the background, newest first, and
  stored as int8 vectors with a scale, keyed by the SHA-1 of the chunk,
  so text met twice is embedded once.  A query's vector is compared
  with every vector in memory, in integer arithmetic.  A failing
  provider is retried later with smaller batches, then shorter chunks;
  changing the model or the dimensions drops the vectors and embeds
  everything again.  Its cost is recorded with `usage/record` under no
  session.
- `session/search-status` → `(:index BOOL :file :size :sessions :nodes
  :pending :progress :embedding (:model :chunks :pending :error))`, or
  `(:index nil :reason …)`; `session/search-rebuild` drops the index,
  vacuums the file and empties its write-ahead log, so that the dropped
  text is gone from `search.db` too (the status it returns has
  `:vacuumed`), and builds it again from the logs.  A secret in a
  transcript is in the index as well, in the rows, in the full-text
  index and in the vectors of the chunks that held it, and deleting a
  row leaves its text in the file: `session/search-redact` and
  `session/search-purge` deal with that (see redact).
- The UI's results buffer (`harness-ui-search-mode`) lists the sessions
  found, each with its best matches, what was found highlighted.  `m`
  cycles the mode, `a` narrows to the project the search started from
  or widens to every project, `s` asks another query, `g` searches
  again and `+` shows more sessions.  RET opens a session at a match:
  `harness-ui-search-visit SESSION NODE REGEXP` opens the session as the
  session list does, then `harness-ui-chat-goto-node NODE SESSION
  REGEXP` loads the transcript and its older pages until the node shows,
  opens a group or fold that hides it (and a long output's hidden part),
  and puts point on the first match of REGEXP in it, the text the
  snippet marked; a node off the session's current branch is reported.
  `harness-ui-search-hit-regexp HIT &optional QUERY MODE` makes the
  REGEXP from a hit's `:snippet` and `:ranges` (for none marked, from the
  query of a literal or regexp search).  Both serve the quick search's
  [Open], whose sessions carry the same `:node`, `:snippet` and `:ranges`
  (see tasks-search).  The conversation tree opens a node the same way.

### tasks-search

The harness's search in words: a query ("did I have a task about the
question button?", "restart the errored tasks", "where did I debug the
merge queue?", "how do I attach a file?") finds tasks, sessions and
commands, and may act on tasks, answered by a cheap model that returns
JSON only.  `search/ask` is its one method, for the whole harness: the
task board asks it favouring tasks, any other view favouring what the
place suggests.  The module requires tasks, provider and session-search:
transcripts are searched by `session/search` (see session-search), full
text, and by nothing else.

- `search/ask CWD QUERY &optional OPTS` → promise of the plan
  `(:query QUERY :model MODEL :bias BIAS :looked LOOKED :session-query
  SESSION-QUERY :note NOTE :widened WIDENED :ids IDS :actions ACTIONS
  :tasks TASKS :sessions SESSIONS :commands COMMANDS)`.  Nothing changes
  yet.  CWD is the
  project the query was typed in, and OPTS a plist:
  - `:bias` what to favour: `"tasks"`, `"sessions"` or `"commands"`
    (singular too).  By default it is what the view of `:context`
    suggests: tasks on the board, sessions in the session list or a
    conversation tree, commands anywhere else.  It only favours: the
    model is given all three kinds whatever it favours.
  - `:context` where the query was typed, `(:view VIEW :title TITLE
    :mode MODE :session ID :project DIR)`: VIEW is `"board"`,
    `"chat"`, `"sessions"`, `"tree"` or another word for any other
    buffer, TITLE and MODE that buffer's, ID the session the user is in,
    which the answer leaves out, and DIR the project.  The model reads it
    as one line ("Context: the chat of session ... Favour commands, then
    sessions; tasks count too.").
  - `:commands` the commands the model may name, the UI's catalogue,
    each `(:command NAME :keys KEYS :where WHERE :label LABEL :doc DOC
    :here HERE)`, HERE true when the command runs where the query was
    typed.  Keys, menus and modes are the UI's to know, and the UI may be
    in another Emacs, so it sends them along; without any, no command is
    named.  Only an entry of the catalogue is ever named.
  - `:shown` the ids the board shows now, which "them" in QUERY means.

  IDS are the tasks QUERY is about, best match first, archived ones
  included, and TASKS those tasks again, each `(:id :title :status
  :session)`, for a view that has no board.  SESSIONS are the sessions it
  is about, of any project, best first, each `(:id :name :kind :status
  :project :cwd :updated :snippet :node :ranges :task)`: `:project` the
  name of its project; `:snippet` the passage around the first match a
  search of the transcripts found in it, on one line, `:node` the id of
  the node that holds it and `:ranges` where the matches are in the
  snippet, each `(START END)` -- all three nil for a session found by its
  name only; `:task` the task of the board it works on or nil.  A view
  opens the session at `:node`, the words found highlighted (the quick
  search's [Open], below).  COMMANDS are the entries of the catalogue it
  is about, best first.  BIAS is what the search favoured, LOOKED says
  what the model looked at besides what it was given, and SESSION-QUERY
  is the text the sessions' transcripts were searched with, or would be:
  what the model asked them for when it looked (`{"sessions":TEXT}`,
  else `{"grep":TEXT}`), else the words of QUERY that say something
  (`harness-tasks-search--content`, those the transcripts up front and
  widening search for), nil when QUERY has none.  A view that shows
  every match in the sessions searches for it (the quick search's
  [All matches], below), not for the line as typed, whose "where did I"
  would only dilute a full-text search.  NOTE is the model's word on the
  answer ("No task matched; these sessions mention it.") or
  nil.  WIDENED is t when the model answered with nothing and the search
  added what comes nearest itself (Widening, below), NOTE saying so, else
  false.  ACTIONS are what QUERY orders, in order, each `(:task ID
  :action NAME :text TEXT :title TITLE :confirm BOOL)`, NAME one of
  `harness-tasks-search-actions` (`archive`, `restore`, `stop`, `retry`,
  `start`, `verify`, `complete`, `message`, `reject`, `priority`), TEXT
  the words a message or a send-back carries or the priority a
  `priority` action gives (one naming none, or the level the task's
  session already has, or for a done task, is dropped), and `:confirm` t
  for an action that interrupts work, merges it or sends words to an
  agent (stop, verify, complete, message, reject, and archive of a
  working task), false for the rest.  `task/search-apply` runs them.
- The first message to the model carries the project and the time, the
  context line, a compact dump of the board, the sessions, the commands
  and the query.  The board is every task (newest first, at most
  `harness-tasks-search--max-tasks`, fewer when the search favours
  something else) with its id, column and state, title, the request it
  was asked in, its priority when it is not medium, the todo it is on,
  what it waits for the user on, the summary it handed in, its branch,
  times and errors.  The sessions are the other sessions, best match of
  their names first and then the newest, at most
  `harness-tasks-search--max-sessions` (a search favouring tasks shows
  only those whose names match), each by the first eight characters of
  its id, its kind, status and project and its name.  The commands are
  those the words of the query match, with their keys, where they apply
  and what they do, at most `harness-tasks-search--max-commands`; a
  search favouring commands that matches few adds the menu's.  The system
  prompt (`harness-tasks-search--system`) is constant, shared by every
  search whatever it favours, and the model must answer one line of JSON
  `{"show":[ID...],"sessions":[ID...],"commands":[NAME...],"do":[{"task":ID,"action":...}],"note":"..."}`.
  Unknown ids and commands are dropped, acted-on tasks are always shown,
  and a session is named by its id or the start of it.
- The transcripts up front.  A search that favours sessions (the
  session list, the conversation tree, [Search sessions]) searches every
  session's transcript before the model reads anything
  (`harness-tasks-search--upfront`): `session/search`, text mode, for the
  words of the query that say something
  (`harness-tasks-search--content`: the query without the stop words of
  `harness-tasks-search--stop-words`, so "where did I write the API
  guide?" is searched as "write API guide": the full-text search wants
  every word, so "where" and "did" would keep it from finding anything
  or, once it settled for some of the words, rank unrelated sessions
  first), leaving out the session the user is in, at most
  `harness-tasks-search--max-found` sessions with their best two
  matches.  What it finds goes to the model as a block of its own
  ("Sessions that mention ..., best first"), ahead of the sessions listed
  by their names, which leave those out, and the sessions are remembered
  with where their first match is (`:node`, `:snippet`, `:ranges`): one
  found by what was said in it can be named after a single call of the
  model, and a view opens it there.  The model's process is taken once
  that search is done.  A search that favours tasks or commands does not
  do this; its model may ask to look.
- Looking further.  When the model asks to look further instead of
  answering, with one object holding any of `{"grep":TEXT}` (the
  transcripts of the tasks' sessions), `{"read":[ID...]}` (the latest
  transcript of at most `harness-tasks-search--read-limit` tasks),
  `{"sessions":TEXT}` (the transcripts and names of every session, not
  only the tasks'; the sessions found are remembered with where their
  first match is) or `{"commands":TEXT}` (the catalogue, matched by
  words), it gets one more round (`harness-tasks-search--final-text`
  closes it) and must answer then.  The prompt tells it to use that one
  look to search beyond what the search favours when that has no answer,
  and to say so in `note`.  A TEXT for "grep" or "sessions" is a
  full-text query for `session/search` (see session-search), and the
  prompt says so: its words match in any form and every word must match,
  "quoted words" match as a phrase, `word*` as a prefix, `a OR b` either,
  `-word` leaves out what has it, best match first, the best two matches
  of each session.  When no session has every word the answer says the
  ones listed have some of them, and when none has any, with an
  embedding model set, that they are the nearest in meaning.  A
  `session/search` that fails is told to the model ("The session search
  failed: ...") and logged as a warning, and the search goes on.
- Widening.  When the answer shows, names and does nothing, the search
  adds what comes nearest itself (`harness-tasks-search--nearest`)
  without asking the model again: the sessions a search of the
  transcripts for the words of the query that say something finds and the
  commands it matches, at most `harness-tasks-search--max-nearest` of
  each, with `:widened` t and a NOTE saying so, or saying that nothing
  matched at all.
- The model is `harness-tasks-search-model`: `auto` (the default) takes
  the provider of the task model's `simple` tier (`provider/tier-model`),
  nil uses the task model itself, a string forces one.
  `harness-tasks-search-thinking` (nil) is its thinking level, the
  output budget is `harness-tasks-search--max-tokens`, and a call taking
  longer than `harness-tasks-search--timeout` fails.
  `harness-tasks-search--request` runs it as a side session in
  `task-search/` under the state directory, so the project's Claude
  history and CLAUDE.md stay out of it.  Every search gets its own
  session id, and its process is closed when it ends
  (`provider/close`).
- `search/warm CWD` → `(:model MODEL :warm BOOL)`: start the model
  process the next search of CWD's project will use (`provider/warm`),
  so the answer comes sooner, whatever the search favours; a process
  left unused is closed after `harness-tasks-search--warm-idle` seconds.
  A search box calls it as it opens.
- `task/search-apply ACTIONS` → promise of one result per action,
  `(:task :action :title :ok :error :undo)`, run in order: archive stops
  a working task first and archives it once it stopped
  (`harness-tasks-search--stop-wait`), stop never drops a task that has
  not started, retry is `task/retry`, message is a follow-up to the
  task's session (or words added to the prompt of a task still waiting
  for a slot, a backlog task's), priority is `priority/set' on the
  task's session -- a task's priority is its session's (its result says
  the priority given, as `:text`), and the rest are the tasks methods.
  ARCHIVE and RESTORE carry `:undo`, the action that undoes them, and
  PRIORITY the priority action back to what the task had.
- Each round of a search is recorded as an internal session, "Task
  search", in the board's project (`session/internal-start`), which
  records the round's cost too; without the session module the cost is
  recorded with `usage/record` under the board's project with
  `:session nil`.
- Settings `harness-tasks-search-model`, `harness-tasks-search-thinking`;
  the demo provider answers search requests heuristically (word match
  plus action verbs, and priority words such as "prioritize", and the
  words of the sessions the transcripts' search listed, the sessions'
  names and the commands' lines), so the dev daemon and the tests work
  offline; the screenshots script answers them from a script of its own.

### harness-redaction

The library (lisp/harness-redaction.el) that names a secret without
having it in a call, finds it, and takes it out of text.  It is loaded
on both sides (it is one of `harness--library-files`): the secrets and
redact modules use it in the harness process, and the UI uses it to
clean the buffers of the user's Emacs.  It stores, emits and logs
nothing, and the errors it signals name labels, fingerprints, paths and
counts, never a value.

- A secret is a plist `(:value V :label L :fingerprint F :source S)`,
  made by `harness-redaction-secret VALUE LABEL &optional SOURCE`.  It
  lives in memory only: it is never stored, logged, emitted, returned to
  a model or put in an error message.  F is the first 8 hex digits of
  the SHA-256 of V (`harness-redaction-fingerprint`), and what takes V's
  place in text is the placeholder `[redacted: L sha256:F]`
  (`harness-redaction-placeholder`).  L is made fit for a placeholder:
  control characters become spaces, `]` becomes `)`, at most 80
  characters are kept, and an empty one is `secret`.  `S` says where V
  was read (`harness-redaction-describe-source`): a file and the path or
  regexp, a variable, "typed by the user" or "command output", never a
  value.
- A reference names a secret by where it can be read:

  ```elisp
  (:file PATH :json-path P [:label L])  ; a string in a JSON file; an object or
                                        ; array selected stands for every string under it
  (:file PATH :regexp RE [:label L])    ; group 1 of each match in a file
  (:env NAME [:label L])                ; an environment variable of the process
  (:literal STRING [:label L])          ; a value typed by the user
  (:command STRING [:label L])          ; the output of a shell command
  ```

  `harness-redaction-resolve REF` → `(:secrets SECRETS :skipped N
  :source DESCRIPTION)`.  SECRETS have no duplicates, the longest value
  first.  A value shorter than `harness-redaction-min-length` (8) is
  skipped and counted in N: a word such as `prod` would be taken out of
  everything.  It signals a `harness-error` when no value is left to
  redact -- the file is missing or holds nothing there, the regexp
  matches nothing or has no group 1 that matched, the variable is unset,
  the command fails or prints nothing, every value is short -- with a
  message that names no value.  Without a `:label` a JSON path labels
  each secret by its path from the root; with one a single secret has it
  and several have `LABEL.` and the path below the part of the path
  before the first `*`; a regexp's secrets are labelled by the file name
  (or the `:label`) and a number when there are several.  A JSON path is
  dot-separated keys, indices and `*`, with `["a.b"]` for a key that has
  dots, brackets or spaces (`harness-redaction-json-path-parse`).
  `:json_path` spells `:json-path` as well, as a tool call does.
- `harness-redaction-shape FILE &optional JSON-PATH` → `(:path P :type
  T)` for every node under what JSON-PATH selects (the whole document by
  default), depth first, the selected node first: the keys and types of
  a JSON file, so that a path can be written without reading the file.
  P reads as a `:json-path`, T is `object`, `array`, `string`, `number`,
  `boolean` or `null`.  Neither a value nor the length of a string is in
  it.  After 1000 entries a last one, `(:truncated t)`, says so.
- JSON stores a string with escapes (a quote as `\"`, and some writers
  escape `/` as `\/`), so a secret has up to three needles
  (`harness-redaction-needles`): its value, its value as JSON escapes it,
  and that with `/` escaped.  `harness-redaction-pairs SECRETS` →
  `(NEEDLE . REPLACEMENT)` pairs, the longest needle first; an escaped
  needle is paired with the placeholder escaped the same way, so that
  replacing in JSON text leaves valid JSON.  Text is scanned once, left
  to right, taking the longest needle at a position and going on after
  it: a placeholder is never searched and a position never counts twice.
- On strings and Lisp values: `harness-redaction-count STRING SECRETS`;
  `harness-redaction-string STRING SECRETS` → `(NEW . COUNT)`, the raw
  values only; `harness-redaction-value VALUE SECRETS` → `(NEW . COUNT)`,
  walking conses and vectors and sharing what did not change.
- On JSON lines: `harness-redaction-jsonl TEXT SECRETS &rest OPTIONS` →
  `(NEW-TEXT :count N :lines L)`.  Only a line that holds a needle is
  parsed and written again; every other line is kept byte for byte, and
  a line that does not parse is cleaned as text.  `:style` is `foreign`
  (the default: objects as alists) or `harness` (as the node logs are
  read and written), `:dry-run` only counts, and `:on-line` is called
  with the old and new object of each line that changed.
- On files: `harness-redaction-file-count PATH SECRETS` counts the
  needles as UTF-8 bytes in any file, text or not, a SQLite database
  included, reading it in chunks.  `harness-redaction-file PATH SECRETS
  &rest OPTIONS` → `(:file :count :changed)`, with `:style` `text` (the
  default), `jsonl` or `json` (one document, written again whole),
  `:json-style` as above, `:dry-run` and `:on-line`.  A file with a NUL
  byte among its first bytes is binary: counted, never changed, and
  `:binary t` is added.  Text is written back atomically with its modes
  (`harness-redaction-rewrite-file PATH TEXT &optional EXPECT`: a new
  file in the same directory, then a rename), so a reader sees the old
  file or the new one.  A file that changed while it was processed is
  processed again, up to three times, and then
  `harness-redaction-changed` is signalled.
- On buffers: `harness-redaction-buffer BUFFER SECRETS &optional
  DRY-RUN` → the count.  A read-only buffer is changed too, the
  placeholder takes the text properties of the text it replaces, and
  undo information that held a secret is dropped.

### secrets

Keeps secrets out of what the harness stores
(lisp/modules/harness-secrets.el; requires store): a registry of the
values of the sources the user named, detectors for what is shaped like
a secret, and the masking that uses both.  It is what the user's
`harness-secrets-*` options and the UI's `harness-secrets-add-source`
act on.

- `secrets/shape FILE &optional JSON-PATH` → `(:file FILE :paths PATHS
  :truncated BOOL)`, PATHS a vector of `(:path P :type T)`: the shape of
  a JSON file by `harness-redaction-shape`, never a value.  It is how a
  client picks the path of a reference without reading the secret.
- `secrets/sources` → a list of `(:id ID :label LABEL :source
  DESCRIPTION :origin ORIGIN :values N :fingerprints (F…) :error
  MESSAGE)`, one for each source in force, never a value.  ORIGIN is
  `config` for a reference of `harness-secrets-sources` (its ID is
  `config-N`) and `stored` for one added by `secrets/add-source`; N is
  how many values the source holds and each F the first 8 hex digits of
  the SHA-256 of one; MESSAGE, when there is one, says why the source
  cannot be read now.  Files and variables are looked at again first.
- `secrets/add-source REF` → the new source as `secrets/sources` lists
  it.  REF is `(:file PATH :json-path P)`, `(:file PATH :regexp RE)`,
  `(:env NAME)` or `(:command STRING)`, with an optional `:label`.  The
  source is read now, which proves it names a value, and kept in
  `secret-sources.json` of the state directory, `{"sources": [{"id",
  "ref", "added"}]}`: the reference, never a value.  A `:literal` is
  refused, as it would put the secret on disk, and so is a reference
  that spells out a value it names (a regexp that quotes the secret).
  Adding what is there already changes nothing.
- `secrets/remove-source ID` → `(:id ID :removed t)` for a stored
  source.  A `config-N` source is the option's to change, and says so.
- Registry.  One entry for each source, the option's first, with the
  values in memory only.  A file is read again when its modification time
  or size changes and a variable when its value does, looked at every 5
  seconds at most.  A source that cannot be read is skipped, its error is
  kept for `secrets/sources` and logged once, it is tried again when its
  file changes or after a minute, and the values it had when it last
  could be read stay in force.  A command runs when its source is first
  read, under `timeout` where that is installed, and again only if the
  reference changes.  The module reads the sources 2 seconds after it
  starts, so a command has run before the first result.
- Detectors.  `harness-secrets-builtin-detectors` maps a name to a
  plist: `:regexp`, `:group` (the part that is masked), `:default`, `:doc`,
  and optionally `:predicate`, `:bounded`, `:case-fold`, `:before` (what
  the text before a match has to end in), `:end` (the regexp that closes
  a block, for a PEM key) and `:late` (tried after the others).  They
  are `digitalocean-token`, `aws-access-key-id`, `spaces-access-key-id`,
  `github-token`, `anthropic-key`, `openai-key`, `slack-token`,
  `google-api-key`, `stripe-key`, `acp-session-secret` (the `hs1_`
  session secret that remote ACP gives a device that signed in), `private-key`
  and `secret-assignment`, which run by default, and `jwt`, which does
  not.
  `harness-secrets-detectors` is `default`, `t`, nil or a list of names,
  and `harness-secrets-extra-detectors` adds `(NAME REGEXP [GROUP])`.
  There is no detector of high-entropy strings: commit ids, hashes, ids
  and base64 data would be masked, and the model could not read them.
- `harness-secrets-mask-text TEXT` → `(MASKED . HITS)`.  The values of
  the registry come first, as written and as JSON escapes them, the
  longest first and labelled by their source; the detectors follow,
  labelled by their name; a text that two find goes to the first.  HITS
  is a list of `(:label LABEL :fingerprint F :count N)` in the order they
  first appear, nil when nothing was masked (MASKED is then TEXT).
  Nothing is masked inside a placeholder, so masking text again changes
  nothing, and a text in which masking uncovered another secret (one
  glued to the first) is gone over again, four passes in all.  The result
  holds neither a secret nor a snippet.
- Filter `tools/output` at priority 5 masks the `:content` of a RESULT
  and adds HITS to its `:meta` as `:masked`.  Filter `tools/output-text`
  at priority 5 masks a string.  Text that masking fails on is replaced
  by "[output withheld: it could not be checked for secrets]" (a result
  also becomes an error), not let through.
- `harness-log-filter-function` (harness-core) is set to a function that
  masks the log.  `harness-log` passes each formatted message through
  it before the log buffer and `harness-log-hook` see it.  A filter that
  signals, or returns what is not a string, leaves the message as it was,
  and a message logged while the filter runs is not filtered again.
- A `permission/decide` stage at priority 3 refuses a call of kind
  `write` whose input holds something that reads like a placeholder
  (final, with a hint on what to do instead).  A placeholder stands where
  a secret was masked in what the model read, and writing it into a file
  puts it where the secret is.  A denied call can be approved by the user
  (see perms).
- `harness-secrets-mask` nil turns all four hooks off.  On is the
  default, with the default detectors and no source.  What it costs:
  a few regexp passes and one exact search per registered value over
  every result and log line, tens of milliseconds for a megabyte of
  output and a fraction of a millisecond for a log line; nothing is
  skipped for its size, as skipping would be a hole.  The price is false
  positives: `secret-assignment` now and then masks a long identifier,
  and the model sees a placeholder where the text was.
- Masking cannot recall what a model provider already received, and
  it does not touch what the user types or the model writes.  The redact
  module takes a secret out of what was stored before.

### redact

Takes a secret out of everything the harness stored, and records that it
did (lisp/modules/harness-redact.el; requires secrets, session, store).
The request names the secret by where it can be read, never by its
value, and everything the engine writes, emits or returns is made of
labels, fingerprints (the first 8 hex digits of the SHA-256 of the
value), session ids, paths and counts, and is checked for the values
before it leaves; a label or a reason that holds one is replaced first.
So the call and its answer hold no secret, and the session that redacts
never has to be redacted itself.  The one exception is a call that
carried the secret in its input anyway (`:input-text`): the session that
made it is added to the scope.

- `secrets/redact PARAMS` → a report.  PARAMS is a plist; a key it does
  not know is refused.
  - `:source REF` (required): `(:file PATH :json-path P)`, `(:file PATH
    :regexp RE)` or `(:env NAME)`; a `(:literal TEXT)` or `(:command
    STRING)` only with `:allow-unsafe-sources`, which the UI and Lisp on
    this machine may pass and a client on another device may not (see
    acp).  `:label` names the secret in its placeholder.
  - `:scope` (required): `session`, the `:sessions` (ids, or the starts
    of ids); `project`, the sessions of the directory `:project` (a
    session belongs to it when its project, or the main checkout of that
    project, is it, or its cwd lies under it); or `all`, every session of
    every project and kind.  `:include-forks` (default t) adds the
    sessions descended from those named (`session/family-ids`).
  - `:mode`: `scan` (the default) counts and changes nothing; `redact`
    takes the secret out.  `:reason` is kept in the records.  `:origin`
    is who asks, `(:kind user)` (the default) or `(:kind session :id
    ID)`.  `:input-text` is the JSON of the tool call that asks.
  - The report is `(:mode :secrets ((:label :fingerprint :source)…)
    :skipped N :scope TEXT :sessions SESSIONS :stores STORES :total N
    :deferred IDS :errors STRINGS :remaining STRINGS :complete BOOL
    :verification V :text TEXT)`.  Each of SESSIONS, those with
    something found or changed, is `(:id :name :project :count :log
    :memory :record :search :claude :copilot :tasks :transcripts :spill
    :temp :nodes :fields :record-fields :files :running :out-of-scope
    :provider :would-reset :cache-dropped :cache-would-drop :context
    :error)`: the occurrences in its node log and record
    (`:count`), in the log, the nodes in memory, the record, the index's
    rows, the CLI logs, the task records and the files, and the node ids
    and field names they were in.  `:provider` is `reset`, `deferred`,
    `failed`, or `kept` for a session outside the scope that shares a
    provider conversation with one in it and whose own transcript still
    holds the secret: the conversation is left as it is, the log they
    share being clean.  A reset also costs the prompt cache of a hosted
    loop's conversation, and the report says whose.  `:cache-dropped` is
    t on a session whose reset dropped its cache (see "Session").  A
    scan has no `:provider`: it gives `:would-reset` t to each session
    whose conversation a redaction would start over (not one it would
    leave `failed` or `kept`) and `:cache-would-drop` t to those whose
    cache it would drop with it (`session/reset-drops-cache-p`).
    `:context` is the tokens that cache holds, on those sessions only.
    STORES lists the stores that are not a session's, each `(:store NAME
    …)`.  ERRORS are the stages that failed, REMAINING what a redaction
    left, and COMPLETE is t when it was a redaction, nothing failed,
    nothing remains and no session waits for a turn to end.  V is
    `(:total N :explained N :unexplained N :ok BOOL :stores ROWS)`, what
    the scan after a redaction found; EXPLAINED are the occurrences in
    files left alone for a stated reason (deferred, busy, binary, too
    large) and, in the files of the search index, in the rows of sessions
    outside the scope.  TEXT says all of it for a person or a model to
    read, the sessions whose conversation starts over, or in a scan
    would, and whose prompt cache goes with it, with the tokens it held.
- `secrets/log &optional LIMIT` → the last redactions (50 by default),
  newest first, from `redactions.jsonl` in the state directory.  The
  engine adds a line there when a redaction ends: `(:ts :time :origin
  :reason :mode :scope :scope-kind :after-turn :secrets :skipped :total
  :totals :sessions :files :deferred :errors :remaining :complete
  :verification)`.  The secrets are named by label, fingerprint and
  source, the totals by store.
- Stores.  A request goes through `harness-redact--store-functions` in
  turn, in either mode (a scan only counts): the sessions' node logs,
  nodes in memory and records (`session/redact-text`); the search index
  (`session/search-redact`); the logs of Claude Code and Copilot; the
  task records, for the scopes all and project (`task/redact`); the
  transcript files that compaction and handoff wrote in the sessions'
  directories (`.harness/transcripts/`, `.harness/handoff/`); the files
  that hold cut tool outputs whole (`outputs/` of the state directory);
  the sessions' temporary directories; for the scope all, every other
  file of the state directory; and the log buffers of the process
  (`*harness-log*`, `*Messages*`, `*harness…` buffers that visit no
  file).  A redaction then resets the provider conversations
  (`session/reset-provider`), has the index read the rewritten logs again
  and purges its files (`session/search-purge`), writes the records,
  scans everything again, announces itself and logs.  Files are counted
  by their bytes first and rewritten only when they hold a copy; one
  that is binary, a database or over 64 MiB is counted and reported as
  found, not redacted; a link is never followed, nor the file the secret
  was read from; a file in a session's temporary directory written in
  the last minute is left alone (`busy`).
- The store methods.  Each takes SECRETS, plists with a `:value` that the
  caller holds in memory (the engine hands them over in the harness
  process: a secret given by a client over the wire is on the wire), and
  answers with ids, kinds, field names, file names and counts, never a
  value, a snippet or an error that quotes one.

  | Method | Does |
  |---|---|
  | `session/redact-text ID SECRETS &optional DRY-RUN` | cleans the node log, the nodes in memory and the text of the record (`name queue pending todos plan ext move`); → `(:id :hit :count :log-count :memory-count :record-count :nodes :kinds :fields :record-fields :file :running)`, and when something was found `:spill-files`, `:checkpoints` and `:provider-state` |
  | `session/reset-provider ID` | drops the provider state, `provider-node` and the `:checkpoint` of every node, in memory and in the log; signals while ID runs a turn; when `session/reset-drops-cache-p` is true it first marks the usage `:cache-dropped` with the moment, so what the reset announces already says the cache is gone; → `(:checkpoints N)`, and `:cache-dropped t` when it marked one |
  | `session/reset-drops-cache-p ID` | non-nil when `session/reset-provider` on ID would mark its prompt cache dropped now: the session reports a cache (a stamp and a context above 0), its model is a hosted loop (`provider/capabilities` says `:hosted-loop`) and no reset marked it since the last request that stamped one; changes nothing; signals for a session that does not exist |
  | `session/family-ids ID` | ID and the sessions whose parent chain reaches it, oldest first |
  | `session/search-redact IDS SECRETS &optional DRY-RUN` | IDS is a list of ids or t; with DRY-RUN → `(:available t :rows N :sessions ((SID . ROWS)…))`, else drops the rows of those sessions and reads their logs again → also `:reindexed`, `:failed`; `(:available nil :reason WHY)` without an index |
  | `session/search-purge &optional SECRETS` | drops the rows of deleted sessions and the vectors no chunk uses, merges the FTS5 segments (`optimize`), VACUUMs and empties the write-ahead log; → `(:available t :seconds :bytes-before :bytes-after :wal-truncated :file-counts :term-counts)`, the counts being the secret's occurrences, and the terms FTS5 makes of it, in `search.db`, its `-wal` and `-shm` |
  | `provider/claude-redact-logs SECRETS &optional CLI-IDS DRY-RUN` | cleans `PROJECTS/SLUG/ID.jsonl` and `PROJECTS/SLUG/ID/` for the CLI sessions CLI-IDS, or every file for t; → `(:directory :count :scanned :files)`, each file `(:file :cli-session :owners :count :status)`, `:status` being `redacted`, `found` (a dry run), `deferred`, `busy`, `binary`, `clean` or `error` |
  | `provider/copilot-redact-logs SECRETS &optional IDS DRY-RUN` | the same for `STATE/ID/` of the Copilot sessions IDS |
  | `task/redact SECRETS &optional PROJECT DRY-RUN` | cleans every string of every task record, writes the stores again at once and redacts `tasks.json.bak`; → `(:count :tasks ((:id :count :fields)…) :files :stores)` |

  Before a CLI log is written, the CLI processes of the sessions that own
  it are closed, so none goes on writing into the old file; the next turn
  resumes the cleaned conversation.  A log whose owner runs a turn is
  `deferred`.  The node log is read, cleaned and replaced in one step
  that never yields: the harness process has one thread, so no append of
  its own falls between the read and the write, no append is lost and no
  log is torn; a log that another process changes meanwhile is read
  again, and left as it was if it keeps changing.  The index is never
  edited in place: a row's text is what its log says, so the logs are
  read again.  Embedding requests that were out are dropped when they
  return, as their vectors are of the old text.
- Provider conversations.  A session whose nodes (the node log or the
  nodes in memory) held the secret, or whose CLI log did, has
  `session/reset-provider` called: its next turn starts a new
  conversation that gets the redacted transcript
  (`session/provider-continuation` says `current` at the head, or
  `fresh`), and does not resume the old one.  A hit only in the record
  (`name queue pending todos plan ext move`) resets nothing: no provider
  conversation was sent those, and a new one is made from the nodes.
  The reset drops the prompt cache of a hosted loop's conversation
  with it, and marks that (`:cache-dropped`, see "Session"): the old
  cache holds the secret, and the new conversation opens with the
  transcript as text, a start the old cache does not hold.  A session on
  a provider that is sent the whole transcript with every request keeps
  its cache up to the first spot that was redacted, and is not marked.
  The session's next message then meets the cold-cache question (see
  cowboy), or `harness-cowboy-default` when nobody is asked.  A scan
  says it beforehand: `harness-redact--stage-scan-providers` decides
  for each session as `harness-redact--stage-providers` would whether
  its conversation is reset (not when its stores failed or it is
  `kept`), asks `session/reset-drops-cache-p`, and gives the report
  `:would-reset`, `:cache-would-drop` and `:context`; the UI's question
  says what the reset costs (ui-secrets).
- Running sessions.  A session that runs a turn is cleaned at once, but
  its provider conversation is not dropped under it and what the turn
  writes next could bring the secret back.  The redaction is kept in
  `harness-redact--pending`, in memory only (the session's `ext` says
  `:redaction-pending`, by label and fingerprint), tool output is masked
  of the pending secrets meanwhile (filters `tools/output` and
  `tools/output-text` at priority 4), and when `agent/turn-ended` says
  the turn is over the stores of that session are gone over again, its
  provider reset and a second record and hint, "after its turn ended",
  written.  Its prompt cache is dropped with that reset, not before, so
  the session's next message meets the cold-cache question from the end
  of the turn on.  A harness that stops first loses the secret from
  memory; when it starts, a flagged session has its provider
  conversation dropped and a hint says to run the redaction again.
- Records.  Each session that changed gets a hint in its transcript
  (labels, fingerprints, where, at whose request, why, and what became
  of its provider conversation) and a record in its `ext`,
  `:redactions`, a list of the last 50: `(:ts :by :reason :secrets
  ((:label :fingerprint :source :count)…) :nodes :fields :record-fields
  :files :counts (:log :memory :record :search :cli :tasks :transcripts
  :spill :temp) :provider :cache-dropped :after-turn)`.  `:by` is "user",
  or "session " and the first 8 characters of its id; `:nodes` has 200
  ids at most; `:cache-dropped` is t, and only there, when the reset
  dropped the session's prompt cache.
  Events: `session/redacted ID RECORD` for each such session, and
  `secrets/redacted SUMMARY` once per redaction (not for the second part
  of one that waited for a turn), SUMMARY being `(:source REF :secrets
  ((:label :fingerprint)…) :sessions IDS)`, REF the reference without
  the value of a literal or the text of a command.  The UI follows both
  (see ui-secrets).
- Tool `redact_secret` (kind `meta`, label "Redact secret", a timeout of
  30 minutes) is `secrets/redact` for an agent.  Its input is `mode`
  (`scan`, the default; `redact`, which needs a `reason`; or `shape`,
  the keys and types of `source.file` with the `json_path` to each),
  `source` (`{file, json_path}`, `{file, regexp}` or `{env}`, never a
  literal or a command), `label`, `scope` (`self`, the default: this
  session and its forks; `sessions`; `project`; `all`), `sessions`,
  `project`, `include_forks` and `reason`.  A key the tool does not know
  is refused without being quoted, in the input and in `source` alike: it
  could be the secret in the wrong place.  Its call and its result are
  kept in the transcript like any other, so the result is made from the
  report: the text of the report, the same for an error, and in `:meta`
  `:redaction` the counts, session ids, labels and fingerprints.  A
  redaction that failed in a store or left a copy behind is an error
  result.  A scan and a shape are reads to the permission chain, a
  redaction is not (`harness-perms--call-kind`), and the jail checks the
  file of the source (`:paths`).
- Adding a store.  A module of your own whose files may hold a copy adds
  a function of the run to `harness-redact--store-functions`.  It finds
  its copies with `(harness-redact-run-secrets RUN)`, only counts when
  `(harness-redact-run-dry-p RUN)`, reports with `(harness-redact-add-store
  RUN (:store NAME :count N …) LINES)`, and credits the sessions it can
  attribute its copies to with `harness-redact-entry-incr` and
  `harness-redact-entry-add` on their entries (the counts the report
  knows are `:log :memory :record :search :claude :copilot :tasks
  :transcripts :spill :temp`; `:files` lists the files changed;
  `:provider-target` t has the session's provider conversation start
  over, and its prompt cache go with it; a store sets it when its copies
  sat in what a provider conversation was sent, as the CLI logs did, and
  the sessions' own store when the nodes held one, not when only the
  record did).  A store that leaves a copy says so in `:left`, a list of
  strings, which the report lists under `:remaining`; a file it leaves
  alone for a reason has the status `deferred`, `busy`, `binary` or
  `not-redacted`, which the verification does not count as lost.
  `harness-redact--verify-functions` take the run after the records are
  written, and `harness-redact--finish-functions` the run and its report
  once it is made, for a redaction only.  The verification runs the store
  functions again on a scan of the same scope.  A reload resets these
  lists to the harness's own, and loads modules of your own after it, so
  the module adds its function at the top level of its file:

  ```elisp
  (defun my-redact-stage (run)
    "Take the secrets of RUN out of my files."
    (let ((secrets (harness-redact-run-secrets run))
          (dry (harness-redact-run-dry-p run))
          (count 0))
      (dolist (file (my-files))
        (cl-incf count (plist-get (harness-redaction-file file secrets :dry-run dry) :count)))
      (harness-redact-add-store run (list :store "my files" :count count)
                                (list (format "My files: %d occurrences." count)))))

  (with-eval-after-load 'harness-redact
    (add-to-list 'harness-redact--store-functions #'my-redact-stage t))
  ```

### pet

A companion pet, after the ones Claude Code hatched for April Fools'
Day 2026 (`/buddy`): an egg hatches into a creature with random bones,
a cheap model names it and gives it a personality, and later, now and
then, lends it a line about the user's work.  One pet per harness.
`harness-pet-enabled` nil turns it off altogether: it reacts to
nothing, grows no more, asks no model anything, and every method but
`pet/get` and `pet/watch` refuses (`harness-error`); a line asked for
before is dropped when it comes.  Its record stays, so turning it on
again brings it back as it was.

- Bones are rolled, never stored: Mulberry32 seeded with the 32-bit
  FNV-1a of the seed and `harness-pet--salt` draws, in order, the rarity
  (`harness-pet-rarities`: common 60, uncommon 25, rare 10, epic 4,
  legendary 1 in 100, with 1 to 5 stars), the species (18 in
  `harness-pet-species`), the eyes, a hat (none for a common one), shiny
  (1 in 100), then the stats DEBUGGING, PATIENCE, CHAOS, WISDOM and
  SNARK (`harness-pet-stats`): from the rarity's floor, one peak stat
  (floor+50 to floor+79, at most 100), one dump stat (floor−10 to
  floor+4, at least 1), the rest floor to floor+39.  A last draw seeds
  the inspiration words the model names it after.  `harness-pet-roll
  SEED` → `(:rarity :species :eye :hat :shiny :stats :inspiration)`.
- `harness-pet-overrides`, a plist, forces attributes over the roll and
  the record: `:name :personality :species :rarity :eye :hat :shiny` and
  the stats `:debugging :patience :chaos :wisdom :snark`.
  `harness-pet-overrides` (the function) reads it as a clean plist,
  dropping what fits nothing (a species, rarity or hat not in the
  tables, a stat that is not a number; a symbol may be a string, stats
  clamp to 1..100, the eye is one character, the name one line of at
  most `harness-pet--max-name` characters).  `harness-pet-roll SEED
  RARITY` draws the hat and the stats as for RARITY, the rarity draw
  still made and a hat for a pet drawn common taken from a generator of
  its own, so nothing else shifts; `harness-pet-bones SEED` is that roll
  with the rest laid over.  The view, the voice
  (`harness-pet--say-system`), the name it answers to, the sanitiser
  and the hatch prompt use the effective bones, name and personality
  (`harness-pet--name`, `harness-pet--personality`); the record keeps
  what the model gave, so dropping an override brings it back.  The VIEW
  carries `:overrides`, the keys in effect as strings.  `pet/rename`
  refuses while `:name` is overridden.  `config/changed` of the option
  emits `pet/changed`.
- The record, `pet.json` under the state directory: `(:seed :name
  :personality :hatched :xp :pets :muted :said)`, SAID its last
  `harness-pet--memory` sayings.  A change it makes while growing is
  saved `harness-pet--save-delay` seconds later (`harness-pet-flush` at
  shutdown and on `kill-emacs-hook`); other changes at once.
- `pet/get` → the VIEW: `(:hatched :enabled :hatching :reactions
  :watching :model :overrides)`, `:enabled` false while it is turned
  off, `:overrides` the attributes `harness-pet-overrides` sets as names
  without the colon, and once hatched also `:seed :name :personality :hatched-at
  :rarity :stars :species :eye :hat :shiny :stats :level :xp :level-xp
  :next-xp :pets :muted :thinking :said`.  Booleans are t or `:false`;
  `:thinking` is t while it waits for a line; LEVEL is
  `max(1, floor((1 + sqrt(1 + 0.8·xp)) / 2))`, a level L starting at
  `5L(L−1)` xp.
- `pet/hatch` → promise of the VIEW once it hatched (the one hatching is
  shared; one that hatched already is returned).  A new seed is rolled
  and the model asked for `{"name":…,"personality":…}`
  (`harness-pet--hatch-system`); with no model, a failed or late call,
  or an answer without them, it hatches all the same with a name from
  `harness-pet--fallback-names` and a plain personality.  Its first
  words follow, as for a petting.
- `pet/pet` (counts, +1 xp at most once a minute, and it answers),
  `pet/rename NAME` (one line, at most `harness-pet--max-name`
  characters), `pet/set-muted BOOL`, `pet/release` (forgets it; the next
  egg brings a new seed) → the VIEW.  `pet/watch CLIENT ON [SESSIONS
  [SELF [OVERVIEW]]]` → the VIEW: CLIENT, an id the UI makes up, shows
  the pet now or not (ON false: nowhere).  SESSIONS, a list of session
  ids: the chats it shows the pet beside, where what it says about each
  shows.  SELF true: it shows the pet itself, its buffer or its figure on
  an overview.  OVERVIEW, a list of session ids: the sessions an
  overview it shows (the task board, the session list) lists, whose
  recaps show there.  ON true with neither list means SELF, as a client
  from before them says it.  A client says it shows the pet only while
  someone is at the screen (in Emacs, while one of its frames has
  focus), so nothing is asked of a model while nobody would read it.
  `harness-pet--watchers` keeps `(:self :sessions :overview)` per
  client.
- It speaks only where it would be seen, and each line is said for one
  scope (`harness-pet--scope`), which the saying keeps as `:scope`:
  `session`, about a session's work, only while some client shows that
  session's chat, and shown there only; `pet`, about nothing in
  particular (a petting, hatching, a level gained with the session's
  chat off screen), only while some client shows the pet itself;
  `overview`, a recap of a session, only while some client shows an
  overview that lists it.  The pet's own buffer and an overview never
  make a session's work seen.  And only while it is on, not muted, and
  `harness-pet-reactions` is on; never two lines within
  `harness-pet--min-gap` seconds, never two at once.  Asked -- a message
  of the user's that names it, a petting, hatching, a level gained --
  it answers every time.  Unasked, at most once every
  `harness-pet-cooldown` seconds (60): on a message the user writes, by
  chance (`harness-pet-chance`, 0.3), and at the end of a turn of the
  user's that failed tests (a command's output, `test-fail`), failed
  otherwise (`error`) or changed more than `harness-pet--large-diff`
  lines (`large-diff`), see `harness-pet-turn-reason`.  It reads the
  session's name, its project and the last nodes of the transcript (at
  most about 3000 characters).
- Its voice (`harness-pet--say-system`) is dry and observant, a
  colleague at the next desk: wry, deadpan, never cloying, with no
  cutesy talk, endearments or anything affectionate, physical or
  sensual, since a cheap model that is petted otherwise writes *nestles
  closer* or *pleased to be touched*.  `harness-pet-actions` (t) lets it
  start a line now and then with a dry gesture between asterisks
  (*squints at the diff*); nil asks for words only.  The hatch prompt
  gives it a dry quirk rather than a cute one, as the personality
  colours every line.  The line is one line, without a leading "NAME:"
  or quotes, and without an action that has a word of
  `harness-pet--suggestive-regexp` (*a spine quivers with pleasure*) or
  `harness-pet--cuddly-regexp` (*nuzzles*, *nestles*, *purrs*), or any
  action while `harness-pet-actions` is nil -- the rest of the line
  stays -- at most `harness-pet--max-saying` characters
  (`harness-pet-sanitise`); "..." is silence.  Some reasons add a steer
  after the context (`harness-pet--steers`).
- System messages: what the harness does to a session the pet tells as
  its own news, in that session's chat (`harness-pet--system-reasons`):
  a new name (`session/updated` with a non-blank `:name`, reason
  `rename`) and a compaction (`compaction/done`, reason `compact`, told
  how much went and how, and steered to a joke about forgetting -- the
  neuralyzer of Men in Black, Memento, Dory and their kin, one at most).
  Neither waits for the cooldown.  One that comes while the pet is
  saying something, or within `harness-pet--min-gap`, waits for it
  (`harness-pet--waiting`, only the newest, for at most
  `harness-pet--wait-limit` seconds, and only while that chat is still
  seen).  When the model fails or has nothing to say, the pet says the
  news plainly ("New name: NAME.", "Compacted. ...").  An internal
  session's are no news.
- Overview recaps: a task card's recap (`recap/done`) and the recap of a
  session that is no task's (`recap/session-done`) are said, reason
  `recap`, scope `overview`, while an overview on screen lists the
  session: the pet puts the recap its own way and names the session.
  Unasked, so at most once a cooldown.  When a turn ends in a session
  that is no task's, an overview on screen lists it and its chat is not
  on screen, the pet has the recap module recap it
  (`harness-recap-session` with FORCE), at most once a cooldown; that
  recap comes back as `recap/session-done`.
- Every call is `provider/complete` with `:ephemeral t` and `:no-thinking
  t`, a session id of its own (closed with `provider/close` when it
  ends) and `pet/` under the state directory as its directory, so no
  project instructions, memory or history reach it; a call taking
  longer than `harness-pet--timeout` is cancelled.  Each call is
  recorded as an internal session, "Pet" (`session/internal-start`),
  which records its cost too (without the session module the cost is
  recorded with `usage/record` and `:session nil`), under the project of the
  session it spoke about.
- Model: `harness-pet-model`, `auto` (the default) the simple tier
  (`provider/tier-model`) of the session's model, or of `harness-model`
  for a hatching or a petting; nil that model itself; a string forces
  one.
- Growing: +2 xp for every message the user writes (the prompt of an
  internal session is none: it grows the pet nothing and gives it
  nothing to say), +1 for every turn
  of theirs that ends well, +3 for every task that gets done
  (`task/done`).  Event `pet/changed VIEW` after any change
  (growing only while watched or when it gains a level), `pet/said
  SAYING` with `(:text :ts :reason :session :session-name :scope)`,
  SCOPE `"pet"`, `"session"` or `"overview"` (a saying from before
  scopes has none: a client takes it for its session's when it names
  one, else for the pet's own).  Both are forwarded to clients; the
  methods are `_harness/pet/...` over ACP.
- The demo provider names pets and speaks their lines from a script,
  a new name, a compaction and a recap included, so the dev daemon and
  the tests run offline.

### notifications

Any module tells the user something with `notification/send`, and
providers deliver it.  NOTIFICATION = `(:title :body :urgency
low|normal|critical :source :kind :session :task :project :url)`: a
title or a body is required, urgency defaults to normal, `:source` and
`:kind` say who sends it and why, `:session`, `:task` and `:project` say
what it is about (a click on a desktop notification opens it), and
`:url` is a link for providers that can open one.  `notification/send`
fills in `:id` and `:ts`.

- `notification/send NOTIFICATION &optional PROVIDERS` -> promise of
  `(:id ID :results ((:provider NAME :status sent|failed|skipped :detail
  TEXT :error TEXT) ...))`, a result per provider, in order.  PROVIDERS
  (names; strings accepted) overrides `harness-notifications-providers`
  (default `(system gotify)`).  The sync filter
  `notification/before-send` (value NOTIFICATION, no args) sees it first
  and may change it, or drop it by returning nil (the result is then
  `(:id ID :dropped t :results nil)`).  Every provider that is set up
  gets it at once; one that signals, rejects or takes longer than
  `harness-notifications--timeout` (30 s) is `failed`, one not set up, or
  unknown, is `skipped`, and neither holds up the others.  It never
  rejects for a provider, and signals when the notification has neither
  a title nor a body.  Event `notification/sent NOTIFICATION RESULTS`.
- `notification/providers` -> `(:name :label :doc :ready :enabled)` for
  every provider, in definition order.
- `(harness-notifications-define-provider 'NAME :label :doc :send FN
  :ready FN)` adds or replaces a provider.  SEND gets the NOTIFICATION
  and returns anything or a promise (a plist's `:detail` says how it
  went); it signals or rejects when it cannot deliver.  READY (no
  arguments, quick: it runs before every notification) says whether it
  is set up; without it, it always is.
- `system`: a desktop notification.  With a client connected
  (`acp/status`), the harness asks it to show one with `client/request
  "_harness/client/notify"` (params `:id :title :body :urgency`, plus
  `:source :kind :session :task :project :url` when set; the URL ends
  the body, and without a title the body's first line is the title), so
  it shows on the user's desktop even for a remote harness, and a click
  on it opens what it is about (see Presentation contracts).  When no
  client answers within 10 s, or every client declines, the harness
  process shows it itself.  Ready while a client is connected or this
  process has a desktop backend.
- Desktop backends (lisp/harness-notifications-desktop.el, loaded on
  both sides): `harness-notifications-desktop-notify &rest (:title :body
  :urgency :on-action)` -> promise of `(:backend NAME :id ID)`.
  `harness-notifications-desktop-backend` is `auto` (the first that
  works of `notify-send`, `dbus`, `terminal-notifier`, `applescript`,
  `osascript`, `w32`; on macOS the three macOS ones first), one of
  those, or a function of that plist.  notify-send runs as an asynchronous process
  with `--print-id` (an id says the server took it) and, with
  `:on-action`, `--action=default=Open`: the process then waits and
  prints `default` when the notification is clicked (at most
  `harness-notifications-desktop-max-waiting` processes wait; an old
  notify-send without these options shows a plain notification).  D-Bus
  calls org.freedesktop.Notifications asynchronously and hears
  ActionInvoked in an interactive Emacs; a batch Emacs, which reads no
  D-Bus events, calls it synchronously with a 2 s timeout and hears no
  clicks.  The body is escaped for markup (`&`, `<`, `>`); the title is
  never markup.  terminal-notifier (macOS; looked for on `exec-path`,
  then in `/opt/homebrew/bin`, `/usr/local/bin` and `/opt/local/bin`)
  gets `-title`, `-message` (required: a lone title is the message,
  under the harness's name), `-activate BUNDLE-ID` and, with
  `:on-action`, `-execute COMMAND`, every value behind a backslash
  (terminal-notifier reads options through NSUserDefaults, which takes
  a value starting with `[`, `(`, `{` or `"` for a property list and one
  starting with `-` for an option, and drops one leading backslash).
  It exits once the notification shows; on a click macOS starts it
  again, and it activates the application and runs the command with
  /bin/sh.  The bundle id is `harness-notifications-desktop-macos-app`,
  else that of the application this Emacs's program is in (read from
  its Info.plist, `org.gnu.Emacs` when that cannot be read) for a
  graphical Emacs or the harness process, else the terminal's
  (`__CFBundleIdentifier`).  The command is
  `emacsclient --socket-name=SOCKET` (or `--server-file=FILE` for a TCP
  server) `--alternate-editor=false --eval "(and (fboundp
  'harness-notifications-desktop-clicked)
  (harness-notifications-desktop-clicked KEY))"`, each word quoted for
  /bin/sh, with emacsclient's full name (found beside this Emacs's
  program, in Emacs.app's `Contents/MacOS/bin[-ARCH]/`, in the `bin/`
  beside the application, then on the path).  The `:on-action` is kept
  under KEY (at most `harness-notifications-desktop-max-actions`, the
  oldest dropped) and runs once, from the command loop; an unknown KEY
  (clicked after a restart, from the Notification Center) runs
  `harness-notifications-desktop-unknown-click-function`.  Without a
  running server (`server-process`) or an emacsclient there is no
  `-execute`, and the log (and the echo area, interactively) says so
  once.  `applescript` runs `display notification` inside a graphical
  Emacs on macOS (`ns-do-applescript`, or the Mac port's
  `mac-osa-script`), from the command loop: the notification is Emacs's
  own, so a click activates Emacs, but no click is heard.  `osascript`
  runs the same in the osascript program, whose notifications macOS
  gives to Script Editor (a click opens Script Editor): the last resort
  on macOS, for a terminal Emacs or the harness process.
- `gotify`: `POST URL/message` through harness-http, the application
  token in `X-Gotify-Key` (so never on a command line), with `title`,
  `message` (the title when there is no body), `priority` (from
  `harness-notifications--gotify-priorities`: low 2, normal 5, critical 8) and `extras`
  (`client::display` `text/plain`; `client::notification` `click.url`
  for `:url`).  Ready once an address and a token are found:
  `harness-gotify-url` and `harness-gotify-token` (a secret), else the
  GOTIFY_URL and GOTIFY_TOKEN environment variables, else for the token
  auth-source (the URL's host, login `harness`; its answer is trusted
  for 5 minutes).  Failures read `Gotify: HTTP 401 Unauthorized: ...`.

### tasks-notify

Notifies the user about tasks through `notification/send` (`:source
"tasks"`, `:task :session :project` set, urgency normal) for the events
in `harness-tasks-notify-events` (default `(review done)`), sent to
`harness-tasks-notify-providers` (nil: the default providers):

- `review` (`task/review`): "Ready for review: TITLE", body "PROJECT: "
  and the start of the agent's last reply (200 characters on one line),
  or "waits for you to verify it or send it back".  Kind `task-review`.
- `done` (`task/done` with HOW `merged` or `finished`; `verified` and
  `completed` are the user's own doing): "Task done: TITLE", body
  "PROJECT: merged into BASE" (or "merged"), or "PROJECT: finished".
  Kind `task-done`.
- `needs-input` (opt-in, from `task/changed`): a task whose `:column`
  turns `needs-input` from another column it was seen in, unless its
  outcome is `cancelled`: "Task needs you: TITLE", body "PROJECT: has a
  question for you", "needs your permission" or "stopped: OUTCOME" and
  its error.  Kind `task-needs-input`.

TITLE is the session's name, else the prompt's first line without its
leading `#`, at most 80 characters; PROJECT is `project/name` of the
task's project.

### patch-review, tools-review

The threads of a task's review, kept where the user's Emacs and the
task's agent both meet them.  `patch-review` is the harness's half of
reviewing a task's changes with the library `change-review` (see
Vendored libraries); its UI half is `ui-patch-review` (see Presentation
contracts, the review of a task's changes), and `tools-review` gives the
task's agent two tools.  The module needs `store`, `tasks` and
`tools-review`.

- The set.  A task is a change set of the library
  (`harness-patch-review--set`, a `change-review-set` with the task's id
  and its title): its versions and its threads.  It is made the first
  time anything asks for it -- `patch-review/get`, an operation, a
  version -- read from the store (`patch-review/TASK-ID.json`: the data
  of `change-review-set-to-data` without the versions' files, which the
  UI reads from the repository) and kept in memory; every change saves
  it (`change-review-save`).  `task/deleted` forgets it.  The module is
  the single writer of a task's threads, so the user's Emacs and the
  agent never disagree: they send operations, the module performs
  them.
- Versions.  `task/review` -- the work was handed in -- records a
  version of the set (`add-version`; one already recorded changes
  nothing): its id and tip are the commit the task's branch ends at, its
  base the merge base with the task's `:base`, read with git in the
  task's project, else its worktree, when that is a directory of this
  machine; a task with no branch, or no repository here, records none.
  Its time, description and title are the report's, and its author the
  agent with its session and the report's `:call-id`, the `hand_in`
  call that handed the work in (`hand_in` puts the id in the report);
  `:meta` holds the `:round` it is (the rounds of feedback before it)
  and the `:branch`.  The id is the SOURCE REVISION every comment made
  against the version records.
- Authors.  The user is `user-full-name` and `user-mail-address` of the
  harness's Emacs, the login name without the first.  An agent is the
  model's name with its session id, and for a comment written with
  `review_comment` the id of the tool call.
- The earlier rounds.  A task sent back before threads existed kept its
  feedback as text.  The first time its set is made, each comment the
  reply format finds in a round of `:feedback`
  (`change-review-mail-parse-reply`: the diff quoted with `> ` and the
  comment under it) becomes a CLOSED thread: by the user, at the
  round's time, against the commit the round names (`(at SHA)`), with
  ids that follow from the task, the round and the comment's place in
  it, so that reading the rounds again adds nothing.  A reply written
  inline, under a quote of the agent's own words (the compose box's
  `C-c >`), keeps the quote above its text as a block quote
  (`harness-patch-review--reply-text`, from the `:prose` the reply
  format returns): "silence" says nothing without the line it answers.
  A paragraph that is only a rule (`---`, `***`, `___`, `===`), typed to
  part two comments, is no comment, and the comments after it keep the
  places they had.
- The words by hand.  `patch-review/import-manual TASK-ID` → `(:added N
  :edited M :threads IDS)`.  Not every reply made it into a round: one
  the user typed in the task's session while the agent worked (a
  steering message, which quotes what the agent said and answers it)
  was never feedback.  The method reads the session's user nodes
  (`session/nodes`) that the user typed -- no `:from` in the node's
  `:meta` (`harness-node-sender`), not the task's prompt, not a round
  (`harness-tasks--reject-message` and the other two openings) -- and
  makes each reply under a quote a closed thread, written by the user at
  the node's time, with the `:meta` `:imported`, `:manual` and `:node`;
  a message with no quote to answer is steering, no comment.  It also
  puts the quote back on the comments of the rounds that an earlier
  import left out, as an `edit-comment` operation, only where the comment
  still has the plain text it was imported with and was never edited.
  The ids follow from the task, the message and the comment's place in
  it, so asking again changes nothing; each change is performed as a
  UI's operation is and announced in `patch-review/changed`.  It is
  asked for, not done on its own: the words of a session are not all
  comments.
- The files viewed.  The files the reviewer compared in Ediff and those
  approved are kept in `patch-review-viewed/TASK-ID.json`: `:seen` and
  `:approved`, lists of `(:path PATH :blob BLOB)` -- the blob the file
  has on the branch, none for a file it deletes, so a file the branch
  changes again is not viewed -- and `:assumed` when files were taken as
  viewed and not looked at (`:revision`, `:tip`, `:time`).
  `patch-review/viewed TASK-ID` → the record (`:seen`, `:approved` and
  `:assumed`, empty when nothing was marked); `patch-review/set-viewed
  TASK-ID KIND FILES ON` marks FILES `seen` or `approved`, or takes the
  mark off (approving views the file too, and a file no longer viewed is
  no longer approved) → `(:seen N :approved M)`;
  `patch-review/assume-viewed TASK-ID &optional REVISION` takes every
  file of the newest version as viewed but those changed from REVISION
  on (default: the commit before the version's tip, so the newest
  commit's files are the ones left to view), replacing the files viewed
  so far and keeping the approvals, from `git diff --raw -z` of the
  merge base against the tip and of REVISION against the tip → a
  promise of `(:seen N :unviewed M :revision COMMIT :tip COMMIT)`.  It
  is asked for, never done on its own: what the reviewer saw is theirs
  to say, so a review with no record has no file viewed, whatever its
  imported rounds name.
- `patch-review/get TASK-ID` → the set as plain data (versions without
  files, threads), made if it was not; `patch-review/apply TASK-ID OP` →
  `(:changed BOOL)`, performing OP, an operation of the library
  (`:op` `add-comment`, `set-status`, `edit-comment`, `delete-comment` or
  `add-version`, the ones a UI makes; any other signals), and nothing
  happens the second time an operation is performed;
  `patch-review/drafts TASK-ID` → the comments not sent yet, as data;
  `patch-review/threads-text TASK-ID &optional STATUS` → the threads
  (`open`, `closed` or all) as text for an agent: "N open, M closed" and
  for each thread its id, status, where it is and its comments with
  their ids and authors -- only the comments sent, since the drafts are
  the user's until they send the task back; `patch-review/comment
  TASK-ID BODY &rest OPTS` → `(:thread ID :status "open"|"closed"
  :comment DATA)` adding the agent's comment.  OPTS: `:thread` (an id,
  or the start of one that is unique, naming a thread to answer; else
  the comment starts a thread), `:status` (`open` or `closed`, set after
  the comment; with no BODY, only the status changes), `:session` and
  `:call-id` (who wrote it: the author's session and tool call),
  `:file`, `:line` and `:side` (where a new thread is), `:revision` (the
  commit the agent was at; else the latest version).  A thread that does
  not exist, a status that is neither, or neither a body nor a status,
  signals an error that says what there is.  All are callable over ACP
  as `_harness/patch-review/…`.
- Event `patch-review/changed TASK-ID OP`: an operation changed the
  threads of a task's review (`change-review-changed-functions`); OP is
  the plist to perform on a copy.  ACP forwards it to every client,
  and each UI performs OP on its own set: the user's own operations
  come back too, and change nothing the second time.
- The drafts go with the feedback.  The module adds
  `harness-patch-review--additions` to
  `harness-tasks-feedback-additions-functions` (see tasks).  Called as
  the task is sent back, it returns the drafts of its set as text: a
  line saying what the quotes are and how to answer
  (`review_comment`, with the thread's id, and close the thread once
  what it raises is done), then each comment quoted from the diff as a
  reply on a mailing list quotes it, a reply in a thread after the
  comments before it, each with its `[thread ID]`
  (`change-review-mail-render-comments`).  Once the task is sent back it
  marks them sent (`mark-sent`, `:round` in `:meta`), and keeps the
  words the user sent it back with, if any, as a sent comment of a
  thread on the change as a whole (`:meta` `:round` and `:words`), so
  that the review has a record of what each round said.  With drafts and
  no words the text is the feedback; with words and no drafts the words
  are kept and nothing is added to them.
- `tools-review` defines `review_threads` (input: `status` open or
  closed, `task` a task id; lists a task's threads with
  `patch-review/threads-text`) and `review_comment` (input: `thread`,
  `body`, `status`, `file`, `line`, `side`, `task`; calls
  `patch-review/comment` with the session, the call id and the commit
  the session's directory is at).  Both are kind `meta` and offered to
  the sessions of tasks only: a filter on `agent/tools` (50) drops them
  from any other, and the catalogue keeps them; `task` names another
  task's review.  They need no approval
  (`harness-perms--auto-allow-tools`), and a supervising session is
  offered them (`harness-supervisor--coordination-tools`): answering
  the reviewer is coordination.
- Tests: test/harness-patch-review-test.el (the module and the tools),
  test/harness-ui-patch-review-test.el (the adapter), and the library's
  own, in lisp/vendor/change-review.

### readonly

Read-only sessions, which look and change nothing: a supervisor
planning, a task's write-up or plan (tasks, Plan mode).  A module
registers a policy (`harness-readonly-register NAME FUNCTION`), a
function of a session plist that returns nil for a session it does not
govern, else a plist: `:tools` (its own tools, besides the reading
ones, `harness-readonly-read-tools`, and the web's,
`harness-readonly-net-tools`), `:except` (reading or web tools it may
not use after all, as `web_fetch` for a session whose mode would only
refuse it), `:label`, `:doing` and `:hint` for the denials.  The first
policy that governs a session decides
(`harness-readonly-allowed-tools`).  An `agent/tools` filter at 90 offers
such a session nothing else; a `permission/decide` stage at 8, before
the jail, the mode and the judge, denies for good a call to anything
else and fails closed (a call it cannot check is denied); and
`tools/sandbox-options` at 90 runs its commands read-only and offline
(`harness-readonly-sandbox-options`) and takes off the `:capabilities`
an earlier filter added (the access module's, for a session the user
gave some), bash being offered only where the sandbox confines the
directory.  `harness-readonly-system-prompt` puts
a policy's own section in place of the tools agent's planning section
(`harness-tools-agent-planning-section`), or at the end without one;
`harness-readonly-budget-point-p N BUDGET` says when to nudge a turn
that reads on: at the budget, then every half budget after.  The
module loads on its own, whether supervisor mode is on or not; the
tasks module requires it.

### supervisor

Supervisor mode: a top-level session on an expensive model plans and
coordinates while workers on cheaper models make the changes, and the
harness enforces it (DESIGN.md, "Supervisor Mode").  A plugin (requires
`session`, `agent`, `tools`) that uses only the generic hooks of the
other modules; without it, and `ui-supervisor`, everything works as
before.  Whether a session supervises is its `:ext` `:supervisor`: `t`,
`:false` (hands-on: the user switched it off) or absent, for a session
the module does not govern (a sub-agent, a side conversation, one older
than the module).  It is set when the session is created
(`session/created`), so the header shows it from the start: a `main`
session with no parent takes `harness-supervisor` as `config/get` has it
at its directory, a fork its parent's value, and a setting its maker gave
in `:ext` stays.  The session of a task takes the task's own `:supervisor'
setting (`task/submit', the board's button, `task/set-all'), else
hands-on for a planned task (`:plan`, the board's Plan mode, whose plan
a strong model made already: `harness-supervisor--task-value`), else
`harness-supervisor-tasks' (`task/changed`, once, while it has no
message and the task was not adopted); the session that writes a backlog
task up only reads, so it
has no setting and `:ext` `:supervisor-write-up` t until the task
starts, when it takes the task's setting.  Only the user changes it later.

`harness-supervisor` and `harness-supervisor-tasks` are each `auto` (the
default), `t` or nil, both layered (`harness-config-keys`) so a project's
.dir-locals.el can decide how its sessions and its tasks start.  `auto`
starts the session supervising and sets `:ext` `:supervisor-judge` t,
and a cheap model decides from the opening message: a subscriber of
`agent/turn-started` sends an ephemeral request beside the session's
first turn (no tools, no thinking, one word asked;
`harness-supervisor-judge-model`, the provider's simple tier by default)
holding the message alone, so the turn never waits for it.  A verdict
starts the session as `supervisor/set` would and writes the note that
says so, with `supervisor/changed`; a provider error, an unusable word
or `harness-supervisor--judge-timeout` takes `:supervisor-judge` away
and leaves the mode it started with, with the note saying that too.  A setting that decides (`t`/nil) and `supervisor/set` both take
`:supervisor-judge` away, so the user's switch is never judged and a
verdict that arrives after it is dropped.  A `submit_plan` or
`retry_step' call the model wrote while the judge was still reading (its
tool list from before the flip) is refused by its handler
(`harness-supervisor--hands-on-result'), so no plan starts behind the
mode's back.  Deleting a session forgets its judgement.  The call is
recorded as an internal session, "Session judge", under the session it
judges (see "provider"); an internal session is itself never governed or
judged.

The note the judge leaves (`harness-supervisor--note') is a hint, which
the model never gets, written in the harness's voice: what was decided,
and what to do about it.  Its `:meta` `:supervisor' holds the record the
chat draws its buttons from (`harness-node-supervisor',
harness-util.el): the judgement, the mode, the setting that decides how
sessions start here and where it is written, and the two actions, each
with the state nil, `done' or `undone'.  `supervisor/act' (SESSION-ID
NODE-ID ACTION) is what a button calls: `always' writes the setting with
`config/set' -- `harness-supervisor' at the session's directory, or
`harness-supervisor-tasks' at the project of the task whose session it
is -- and takes it back out of that layer with `config/unset', `mode'
switches the session as `supervisor/set' does.  Each call moves its
action on, records the state in the note (`session/update-node', so the
chat redraws it with its [undo], then [redo]) and answers with the state
and a message for the echo area.  Only the user calls it.

- `supervisor/set SESSION-ID ON` → session plist: ON `t` for on, `:false`
  or nil for off, stored as `:false`, never removed.  Adds the hint
  "Supervisor mode on" or "Supervisor mode off" and emits
  `supervisor/changed SESSION-ID ON` (`t` or `:false`).  Nothing else
  changes it: there is no tool.  `supervisor/get SESSION-ID` → `t`,
  `:false` or nil; `supervisor/active-p SESSION-ID` → non-nil when it
  supervises (nil for a session that is not there).  On takes effect at
  the next tool call, since the permission stage reads the live session,
  off at the next step, for the tool list.
- `supervisor/set-all ON &optional FILTER` → the ids changed, newest
  first: `supervisor/set` for every governed session (`supervisor/get`
  non-nil: a top-level session or a fork) FILTER of `session/select`
  selects, the same filter as `session/set-all`, `(:active t :tasks t)`
  from the UI, completed tasks' sessions left out by the selection, or
  `(:ids IDS)` from the session list's supervisor command for its marked
  sessions.  A sub-agent, a side conversation, an internal session, a
  session from before the module and one already at the asked value are
  left alone; each change is the
  same `:ext` setting, hint and `supervisor/changed` event as
  `supervisor/set`.  Only the user does this, over ACP as
  `_harness/supervisor/set-all` with `:on` and `:filter` (the UI's
  `harness-set-supervisor-all`, the menu's V); there is no tool.
- Settings: `harness-supervisor` (`auto`: a cheap model judges the
  session from its opening message; `t` always supervises and nil is
  always hands-on; layered like `harness-model`, see config),
  `harness-supervisor-tasks` (the same three, for the sessions of
  tasks, also layered, so a project decides how its tasks start),
  `harness-supervisor-judge-model`
  (`auto`: the provider's simple tier, else the session's own model),
  `harness-supervisor-tiers`
  (nil: an alist from `simple`, `medium` or `hard`, or the names of old
  `mundane` and `standard`, to a model id or a plist `(:model ID
  :thinking LEVEL)`, either key left out to keep the default),
  `harness-supervisor-step-budget` (30) and
  `harness-supervisor-fork-limit` (tokens, 20000; nil for no limit), in
  the settings section "Supervisor mode".  The thinking levels are the
  tiers' own, in the providers' tier settings (section "Model tiers":
  see provider).
- Thinking levels go with the tier.  A supervisor plans on the hard
  tier, so a session whose provider's hard tier names a thinking level
  (`provider/tier-thinking MODEL 'hard`: DeepSeek's `max`, none for
  Claude), fitted to its model (`provider/fit-thinking`), has its
  thinking raised to that level while it supervises:
  `session/ext-changed` on `:supervisor` with
  a true value calls `session/update` `:thinking LEVEL` `:silent t`,
  remembering what it had in `harness-supervisor--raised` (and the level
  it raised it to), and a false or nil value puts the remembered level
  back only while the session still holds the raised one, so a level
  chosen meanwhile stands.  A session whose level was not remembered
  (after a restart) keeps the raised one; deleting a session forgets it.
  This covers a top-level session, a fork that takes its parent's
  setting, a task session (including one `harness-supervisor-tasks` turns
  hands-on right after creation, whose level is put back), and the user
  turning the mode on or off.  `harness-supervisor--thinking` reads the
  level.
- Enforcement, in order.  Filter `agent/tools` (90) offers a supervising
  session only an allowlist: the reading tools (`read_file grep glob
  list_dir file_info`, the `session_*` and `task_*` that only look,
  `skill_search skill_load notification_providers`, `emacs_buffers
  emacs_windows emacs_buffer emacs_describe emacs_find_definition
  emacs_messages emacs_open`, `watch_events unwatch_events`),
  `web_fetch web_search`, the coordination tools (`ask_user todo_write
  hand_in notify session_control session_send session_move
  set_non_interactive set_priority task_control task_submit
  session_settings review_threads review_comment`), the tool that asks
  for a directory (`harness-perms-dir-tool`) and
  `harness-supervisor-tools` (`no_plan_needed submit_plan
  retry_step`), plus `bash` when
  `sandbox/confined-p` says its directory is confined.  Any other
  session loses `harness-supervisor-tools`; the catalogue (no session)
  stays whole.  `permission/decide` stage 8 (before the jail, the mode
  and the judge) denies a supervising session's call to anything else
  for good: `(:behavior deny :final t :reason "supervisor mode: …"
  :hint …)`, the hint pointing to a plan step or to the user switching
  the mode off.  No permission mode, rule or answer lets it through,
  and it holds when the model still has an old tool list.  It fails
  closed: a call it cannot check is denied.  It only refuses; stage 28
  (the next bullet) decides the supervisor's own tools.  Filter
  `tools/sandbox-options` (90) adds `(:read-only t :network nil)` to the
  commands of a supervising session, and the same when it fails.
- Approving plans.  A plan changes nothing by itself: each call of its
  workers goes through the whole permission chain in the worker's own
  session, by that session's mode and judge.  So the user alone approves
  one, and only in ask mode.  `permission/decide` stage 28
  (`harness-supervisor--approval`, after the mode and the standing rules
  at 20 and the tasks module's write-up gate at 25, before the judge at
  30) acts on a supervising session's call of `no_plan_needed`,
  `submit_plan` or `retry_step` whose decision is still `ask`.
  `submit_plan` and `retry_step` stay `ask`, to be answered at 90, when
  the session's mode is ask and it is not non-interactive; in
  accept-edits, auto and yolo mode, and in a non-interactive session
  whatever its mode, they become `(:behavior allow :reason "a plan is
  approved by the user in ask mode only, and no judge rules on plans:
  …")`, so no judge sees one.  `no_plan_needed` only records a decision
  and is allowed in every mode.  The mode and the user's presence are
  `harness-perms--mode-of` and `harness-perms--non-interactive-p`, which
  the stage uses when they are defined and never requires: without the
  permission module the plan tools are left as they are.  A decision made
  before it stands, as only an `ask` is touched: stage 8's refusals, a
  standing deny rule (`harness-perms-rules`), the write-up gate.  A stage
  that signals is skipped, so a failure is logged and the decision goes
  on unchanged; failing closed is stage 8's.
- Turns.  The decision tools are `harness-supervisor-decision-tools`
  (`no_plan_needed submit_plan retry_step hand_in task_submit
  task_control session_send session_control session_settings`); a call
  is noted from `agent/tool-call` (`harness-supervisor--decision-call-p`:
  a `session_settings` call counts only when it changes a setting, since
  a read decides nothing), and a result that is an error takes it back
  out (`tools/finished`), since it decided nothing.  `session_settings`
  is a decision because giving a worker a larger window or a stronger
  model is coordination, like `session_send`, not hands-on work.  The
  async filter
  `agent/stop` (see agent) answers a supervising session's stop with no
  decision in its turn by `(:stop nil :message REMINDER :from
  (harness-sender-system "supervisor"))`, twice at most in a turn; after
  that the turn ends and the hint "The turn ended without a decision"
  joins the transcript.  Every tool call of a supervising turn is
  counted (`agent/tool-call`; `agent/turn-started` resets it), and when
  the count reaches `harness-supervisor-step-budget`, and every half
  budget after (30, 45, 60…), the session is steered by an
  `agent/prompt` from the same sender to submit its plan: a nudge, never
  a stop.  The budget is small because the workers read the code they
  change, so a supervisor needs only enough to split the work, and the
  nudge says so.  It was 80, taken from 164 real sessions (the median
  made 61 tool calls before its plan, the 75th percentile 80 and the 90th
  103) under a prompt that had supervisors gather everything for their
  forks.  `no_plan_needed reason` (`reason` required) records the
  decision and a hint "No plan needed: REASON", and does not end the
  turn.  The sync filter `agent/system-prompt` (900) puts
  `harness-supervisor-prompt-section` in place of the Planning section
  (`harness-tools-agent-planning-section`; else at the end), the same
  text on every call, as the prompt is part of the cache.  The section
  tells the supervisor that its tokens are the expensive ones, each call
  re-reading the whole conversation on the hard model; to investigate
  only what the plan needs (where the work goes, how it splits, what the
  parts share); to write each prompt for its tier (a medium worker can do
  a whole programming task from a ticket-sized brief: the goal, the
  constraints, the decisions, the files it owns, how to verify; a simple
  worker needs its edits spelled out file by file); to split no further
  than parallel work or a cheaper tier calls for, since fewer, larger
  medium steps cost less; to plan for parallel work, in units that each
  own their files, with the shared components defined once in the
  summary and given a first step of their own only when the others
  cannot be written against their spec; that steps are fresh by default
  and a fork is only for a short conversation; not to poll or read the
  workers while they run; and to check a finished plan by what settles
  it most cheaply (the reports, a diff, the test output), not file by
  file.  The `submit_plan` description says the same about the summary,
  the prompts, the tiers and the contexts.
- Plans are the session's `:ext` `:supervisor-plans`, oldest first, in
  the JSON the store keeps, so they survive a restart; each change of a
  step is `session/ext-changed ID :supervisor-plans PLANS`.  Plan:
  `(:id "p-…" :title :summary :node :call-id :created F :fork-tokens N
  :steps (STEP…))`, `:node` and `:call-id` being the call that submitted
  it, which every fork step forks the supervisor at, and `:fork-tokens`
  the estimate, in tokens, of the conversation such a fork inherits,
  measured when the plan was accepted
  (`harness-supervisor--conversation-tokens`).  Only a plan with a fork
  step has it: `harness-supervisor--fork-tokens` reads it, or measures
  the conversation as it is now for a plan stored without it.  Step:
  `(:id :title :prompt :tier
  :reason :context :after (ID…) :model :thinking :state :session
  :attempts N :result :error :worker-model :previous)`: `:tier`
  simple|medium|hard (hard only after `retry_step`; a plan of old's
  mundane and standard read as simple and medium), `:thinking` the
  level its tier names, if any, `:context` fresh|fork (fresh when the
  step names none), `:state`
  pending|running|done|failed|interrupted|cancelled|superseded,
  `:session` the worker, `:result` its last reply, `:worker-model` the
  model the worker was made for (`retry_step` may change `:model`
  afterwards) and `:previous` the attempt before one that started again,
  `(:attempt N :session SID :model MODEL :error TEXT)`.
  A new plan supersedes the earlier plans' steps that have not started;
  their running steps finish as usual.
- `submit_plan summary steps &optional title`, `steps` being `{id, title,
  prompt, tier, reason, context, after}` and `context` `fresh` unless it
  says `fork`, is refused whole, every
  problem named, for an id used twice, an `after` naming no step, a
  cycle, a `hard` or unknown tier (a plan's steps are simple or medium:
  the supervisor runs on the hard model, and a step that would need it
  is not broken down enough), an unknown context, a blank prompt, or
  fork steps while the supervisor's conversation is past
  `harness-supervisor-fork-limit` (the fork limit, below).
  Otherwise it
  records the plan, sets the session's plan (`session/set-plan`) to the
  summary, adds a `plan` node and the hint "Plan submitted: N steps",
  starts the ready steps and ends the turn (`:end-turn t`).  Its answer
  lists the steps, each with its model, tier, thinking level, ", fork"
  when it is a fork step, and the steps it follows.
  `retry_step step reason &optional plan tier prompt` runs a failed,
  interrupted (by a restart, or as its task went back to the queue) or
  cancelled step again on a new worker (`plan` defaults
  to the latest that has the step, `tier` moves it to that tier's model
  and level, simple, medium or hard, the only way a step reaches hard;
  `prompt` adds notes to its prompt) and does not end the turn.  Both
  are kind meta.  No step ever runs on the frontier tier.
- Models.  A step runs on `harness-supervisor-tiers` for its tier, else
  the model of the supervisor's provider of the same tier
  (`provider/tier-model` simple, medium or hard), else the supervisor's
  own, with a hint.  Its `:thinking` is the level
  `harness-supervisor-tiers` gives the tier, else the one the worker
  model's provider names for it (`provider/tier-thinking`: DeepSeek's
  `low`, `high` and `max`), fitted to the worker's model; nil when
  neither names one.  The answers of `submit_plan` and `retry_step` and
  the report of a failed step name it.
- Workers.  A step whose `:after` steps are all done starts: a worker
  session of kind `subagent` named "Step ID: TITLE" is made, with
  `:context-window-limit` from `harness-tools-agent-context-limit`.  A
  step is fresh unless its `:context` is `fork`.  A fresh step is a
  `session/create` in the supervisor's directory, worktree and host,
  with the supervisor as its parent and the supervisor's permission
  mode, thinking level, non-interactive switch and allowed directories;
  the thinking level is the step's `:thinking`, else the supervisor's
  own, fitted to the worker's model
  (`harness-supervisor--worker-thinking`).  A fork step forks the
  supervisor (`session/fork`) at the plan's `:node` and `:call-id`,
  through `seed/fork` when the plan has two or more fork steps on the
  step's model, so that the context is written to that model's cache
  once, and is given the thinking level as `:thinking` when it differs
  from the supervisor's, so that a raised supervisor level is not
  inherited.  How a fork step's worker is made also depends on the size
  of the conversation and on the attempt (the next two bullets).
  The worker gets one `agent/prompt`, from the supervisor session, of
  these parts in this order: the `:preamble` of `seed/fork`; an opening
  (a fresh worker is told that it starts without the supervisor's
  conversation, a fork that it is a worker now; both that other workers
  may run at the same time in the same working tree, so it keeps to its
  step's files); the plan's summary ("## The plan"); the step; the
  plan's other steps, a line each in the form `- ID: TITLE (after A,
  B)`, leaving out the step itself and any that a later plan superseded
  ("## The other steps"); the attempt before it when the step starts
  again (below); what the steps before it reported (each cut to 2000
  characters); and a closing that asks for a short report of what
  changed, how it was checked and anything the other steps need to know.
  The summary and the other steps go to a worker with no `submit_plan`
  call in its conversation, a fresh one or a fork compacted before its
  first turn; a fork that inherits the whole conversation has the call,
  which holds both, and gets neither.  So the supervisor writes what the
  steps share once, in the summary: the approach, the interfaces, names
  and data shapes, and which step makes each.  Workers carry no
  `:supervisor`: they have every tool.  A worker's turn ending
  `end-turn` or `max-tokens` makes the step done; any other end, or no
  worker, makes it failed.
- The fork limit.  No fork reads its parent's prompt cache: its system
  prompt names its own directories, its tools differ from the
  supervisor's, and its model usually does.  So a fork's first request
  writes the whole conversation into its model's cache, and every request
  after it reads it again; with a long supervisor conversation and
  several workers that was most of a plan's cost, which is why a step is
  fresh by default.  A fork step is allowed only while the conversation
  is short.  `harness-supervisor--conversation-tokens SESSION-ID`
  estimates it from the transcript, the text the provider is sent
  (`session/messages`), at about four characters a token
  (`harness-estimate-tokens`); a tool call counts by its input and a
  tool result by its output.  The estimate leaves out the system prompt
  and the tools, which a fresh worker has too, and the thinking, whose
  signatures tie it to the supervisor's model.  `submit_plan` measures it
  when a step is a fork, before the plan or a hint joins the transcript.
  Past `harness-supervisor-fork-limit` (nil is no limit)
  `harness-supervisor--fork-problems` refuses the plan with one problem
  that names the fork steps, the size and the limit and tells the
  supervisor to make them fresh and to put what the workers need in the
  summary and their prompts.  An accepted plan with a fork step keeps the
  estimate as `:fork-tokens`.  A fork step whose plan is past the limit
  all the same, because it was made before the limit existed or the limit
  was lowered since (`harness-supervisor--fork-tokens` reads the plan's
  estimate, or measures the conversation as it is now for a plan stored
  without one), is neither forked whole nor forked through a seed, on its
  first attempt as on any other: the worker is a `session/fork` onto the
  model, compacted before its first turn as a step that starts again with
  no warm seed is (below, `harness-supervisor--compact-fork`).  This
  branch of `harness-supervisor--make-worker` comes before the one for a
  step that starts again.
- A step that starts again (`:attempts` above 1: `retry_step`, perhaps
  on a higher tier, or an interrupted, failed or cancelled step run
  again) decides a fork worker's context by the cache; a fresh step that
  starts again is a `session/create` like the first time, with the
  attempt before it in its message.  A fork never shares its parent's
  cache, a higher tier is a model that never read the plan's
  conversation, and a new fork has no `:cache`, so the cowboy's gate
  never finds it cold: forking the supervisor as a first attempt does
  would send all of it uncached at that model's price.  With
  `seed/warm-p` holding for (the supervisor, the plan's `:node`, the
  step's model), a seed whose cache is warm or which a turn is warming,
  the worker forks through `seed/fork` as above.  Otherwise it is a
  `session/fork` onto the model, compacted before its first turn:
  `cowboy/compact` on the fork (`:why` "No prompt cache on MODEL holds the
  supervisor's conversation", `:by cold-start`; the cowboy's default, a
  brief summary unless the user chose otherwise); with no cowboy,
  `compaction/compact` `:kind brief` and a hint on the fork; with no
  compaction, the whole conversation and a hint.  A compaction that fails
  fails nothing.  The worker plist that `worker-made` gets then has
  `:context-cache` `seed`, `compacted` (and `:compaction`, the kind of
  node the fork wrote) or `whole`, plus `:fork-limit` t when the fork
  limit sent it here, and the supervisor a hint naming the
  step, attempt, model and which it was ("Step s2 (attempt 2) on M:
  forked from the warm shared context", "…no warm prompt cache holds the
  plan's conversation, so its worker starts from a brief summary of it
  rather than reading it all uncached", "…and it was not compacted, so
  its worker reads it all uncached"; for the fork limit "…the plan's
  conversation is past harness-supervisor-fork-limit, so its worker
  starts from a brief summary of it rather than inheriting all of it").
  First attempts within the fork limit and fresh steps are unchanged.
- The attempt before.  Before it wipes `:session` and `:error`, a step
  that starts again keeps its worker in `:previous`, when it had one, with
  the model the worker ran on: its session's, else `:worker-model`.  The
  worker's message then has a section "## The previous attempt" after the
  step and the other steps, naming the attempt, model, session and how it
  ended, and pointing at `session_read` on that session so as not to
  repeat what failed; for a compacted fork the opening adds that the
  conversation before the message was compacted into a summary and
  `session_history` searches what it replaced.
- Reports are messages of the harness's `(harness-sender-system
  "supervisor")` through `agent/prompt`: an idle session starts a turn,
  a running one is steered.  A step done is a hint ("Step ID done on
  MODEL") and starts the steps that waited.  A step that failed, was
  interrupted or was cancelled (its worker session deleted) is a message
  of its own: the step, tier, model and attempt, why, the worker's last
  reply, the steps held on it and those running, and the ways on
  (`retry_step`, a new plan, `ask_user`); the steps interrupted together
  because their task went back to the queue share one message (below).
  When no step is left but done
  or superseded ones, a message lists each step's result and asks to
  check the work "as cheaply as settles it: the reports above, a diff,
  the test output", reading a file, or a worker's session with
  `session_read`, only where a report leaves doubt, and decide (`hand_in`
  in a task).  A report that comes
  while the turn that submitted the plan is ending would be lost with
  it, so it is held until `agent/turn-ended`, and queued for the user's
  next message when that turn ended any other way than `end-turn`.
- Filter `agent/outstanding` reports "Supervisor plan: N steps running,
  M waiting, a report to deliver" while steps run, pending steps can
  still start or a report is held; a step held behind one that did not
  get done is not counted, the supervisor having been told.  The tasks
  module keeps the task of the session active, waiting, meanwhile.
- Filter `agent/stop-outstanding` (see agent) stops that work when the
  tasks module sends the session's task back to the queue, pre-empted or
  returned (`harness-supervisor--stop-outstanding`).  Every step stored
  `running` becomes `interrupted`, with REASON as its `:error` ("its task
  was returned to the queue" without one), and `retry_step` runs it
  again.  Each step's entry in `harness-supervisor--live` goes first, so
  that nothing its worker does later changes the step: its turn ending,
  being cancelled, or the worker being made at last
  (`harness-supervisor--making-p`: a worker is made for one attempt, so
  one made after its step was interrupted, perhaps started again since,
  is given up and never gets the step).  Every step is stored before any
  call is closed, so that no report names another as still running; each
  step's `spawn_agent` call gets its result, and the worker is stopped
  (`harness-supervisor--stop-worker`): `agent/stop-outstanding` for the
  worker first, which stops the sub-agents it started, then
  `agent/cancel`.  A step stored running that no worker runs in this
  process, one a restart left, is interrupted too, so that nothing is
  outstanding afterwards.  The steps are reported in one message of the
  harness's `supervisor` -- that the plan's workers were stopped, why,
  that nothing runs or starts again on its own, then each step as a
  failure is reported, ending "Decide: retry_step ID to run it again" --
  so that a task's session, which refuses the turn it would start while
  its task waits in the queue, keeps one message and not one for each
  step; the session of anything else gets it queued, for the user's next
  message.  Nothing starts: the steps held behind an interrupted one wait
  for the supervisor.  The value of the filter gains "Supervisor plan: N
  steps interrupted", and is left as it was when no step ran.
- Restarts and deletion.  Workers die with the harness: once every
  module is up (`harness-run-soon`), the steps stored as running that
  this process has no worker for are `interrupted` and reported as a
  failure is, to the session of a task as a message, so the task carries
  on (and its ready steps start again), to any other session queued
  (`agent/prompt` `:queue t`), to go with the user's next message instead
  of starting an expensive turn unasked.  A reload hooks in again and
  starts nothing.  Deleting a supervisor cancels its running workers,
  deleting a worker cancels its step, and switching the mode off lets
  the workers carry on.
- Events.  Emits `supervisor/changed SESSION-ID ON`, and
  `session/ext-changed` through `session/set-ext` for the setting and
  for every change of a plan's steps.  Subscribes to `session/created`,
  `task/changed`, `agent/turn-started`, `agent/tool-call`,
  `tools/finished`, `agent/turn-ended` and `session/deleted`.

### seed

Seed sessions (module `seed`, requires `session`, `agent`): forks onto a
model that share one warm prompt cache.  A provider's cache serves only
the model that wrote it and only a request that starts with the very
prefix the writing request had, the tools, then the system prompt, then
the messages, word for word.  Forking a long session onto a cheaper
model makes each fork write the whole context into that model's cache,
and two forks never share a prefix, since a session's system prompt
names its own working and temporary directories.

- `seed/fork SOURCE-ID MODEL &rest PLIST` → promise of the new fork's
  session plist plus `:seed`, the id of the seed it was forked from, and
  `:preamble`, a string or nil.  PLIST: `:node` (default SOURCE-ID's head;
  the seed, and so the cache, belongs to (SOURCE-ID, NODE, MODEL), so a
  caller forking one turn several times gives the same node each time,
  the head moving), `:call-id` (as for `session/fork`), `:seed-name`
  (default "Shared context for SOURCE (MODEL)") and any `session/fork`
  key of the fork (`:name :cwd :worktree :kind`, default `subagent`,
  `:id`…); a nil MODEL is SOURCE-ID's own.  The steps: find or make the
  seed, a `subagent` fork of SOURCE-ID at NODE onto MODEL that is sent
  `harness-seed-prime-message` and whose turn is waited for; warm it,
  sending `harness-seed-warm-message` when `session/get` gives it no
  `:cache` or one that lapses within `harness-seed-warm-margin` (30)
  seconds; fork the seed at its head with PLIST.  Calls for one key at
  the same time share the first two steps.  A seed turn that does not end
  well, or a fork that cannot be made, rejects the promise, and the
  caller may fork SOURCE-ID directly; errors of the call itself reject
  it too, since it always returns a promise.
- Frozen prompts.  The sync filter `agent/system-prompt` (1000, after
  every other section) records each seed's final prompt, and a fork made
  here sends it, as it was when the fork was made, in place of the one it
  would assemble.  It names the seed's directories, so `:preamble` is a
  text for the fork's first message that names the fork's own (nil when
  nothing differs).  The records are in memory only: after a restart a
  resumed fork assembles its own prompt, which is right, just uncached,
  and the next call makes a new seed.
- The seed's messages are the harness's (sender "seed") and leave the
  seed as it is, its transcript being the prefix the forks share and its
  model the one whose cache they read: the `agent/before-turn` stage at
  5 sends such a message through the stages from 21 on only, leaving out
  the ones that would change either, fallback and handoff (10), the
  cold-cache question (cowboy, 15) and compaction (20).  The budgets
  (from 30) still apply.
- `seed/warm-p SOURCE-ID MODEL &optional NODE` → the id of the seed or
  nil: whether `seed/fork` for (SOURCE-ID, NODE, MODEL) would find the
  shared context in a cache that lasts.  Non-nil when a known seed
  exists for the three, running on MODEL, and either its cache is warm
  (not gone, and not lapsing within `harness-seed-warm-margin`) or it
  runs a turn now, being primed or warmed, which a fork waits for.  NODE
  nil is SOURCE-ID's head and MODEL nil its own model, as for
  `seed/fork`.  It only reads: no seed is made, primed or warmed, and
  none forgotten but a stale one that the lookup drops as `seed/fork`
  would; it never signals, an error being nil.  A caller that can do
  without a seed asks it to choose between forking through the seed and
  compacting a fork (the supervisor, for a fork step that starts again).
- `seed/list &optional SOURCE-ID` → seeds, newest first, `(:id :source
  :node :model :cache)`, for diagnostics and the UI; kept in memory, so
  one made before a restart is not listed, though its session remains.
- A seed is an ordinary session of kind `subagent`, in the session list
  and readable, deleted with `session/delete`; nothing deletes one.  Its
  forks are children of the seed, not of SOURCE-ID, so whatever is keyed
  on `:parent-id` (the merge queue, say) sees the seed as their parent.
  Its record carries `:seed t` in its `:ext` (set with `session/set-ext`
  when the seed is made), which goes to every client with the record:
  the UI reads it with `harness-ui-seed-session-p` and
  `harness-ui-navigable-session-p`, and leaves seeds out of navigation
  (the header's link to the parent, `harness-open-latest-session`, the
  session pickers).  The supervisor module forks the workers of its fork
  steps this way, when a plan has two or more on one model.

### tools-fs, tools-shell, tools-ssh, tools-emacs, tools-emacs-eval, tools-web, tools-agent, tools-question, tools-plan, tools-todo, tools-session-info, tools-sessions, tools-events, tools-notify, tools-handin, tools-compact, tools-review

Tool names, labels and inputs (all paths relative to cwd or absolute;
TRAMP prefixes come from the session host):

| tool | label | input | kind |
|---|---|---|---|
| `read_file` | Read file | path, offset, limit | read |
| `write_file` | Write file | path, content | write |
| `edit_file` | Edit file | path, old_string, new_string, replace_all | write |
| `list_dir` | List directory | path, depth | read |
| `glob` | Find files | pattern, path | read |
| `grep` | Search files | pattern, path, glob, case_sensitive, max_results | read |
| `bash` | Bash | command, timeout, cwd | exec |
| `ssh` | SSH | host, command, cwd, timeout | exec (tools-ssh; its path is the directory it runs in on the host, or the login's home directory by name, `/ssh:HOST:~/`, when the host decides where that is: no cwd, a relative cwd) |
| `elisp` | Emacs Lisp | code, timeout | exec |
| `emacs_buffers` | List buffers | filter, all | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_windows` | List windows | — | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_buffer` | Read buffer | name, offset, limit | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_open` | Open buffer | name (buffer or path), line | read |
| `emacs_insert` | Insert text | name, text, position (point/start/end) | write |
| `emacs_save_buffer` | Save buffer | name | write |
| `emacs_describe` | Describe symbol | symbol, buffer | read (needs no approval: `harness-perms--inspection-tools`) |
| `emacs_find_definition` | Find definition | symbol, type (function/variable/face) | read (needs no approval: `harness-perms--inspection-tools`; the file of a definition it shows becomes readable, `permission/reveal-file`) |
| `emacs_trace` | Trace symbol | action (start/stop/list), symbol, type (function/variable), callers, limit | write |
| `emacs_eval` | Evaluate in Emacs | code | exec (tools-emacs-eval; offered only while `harness-emacs-eval` is on, as it is by default; a judge model, which may look up what it does not know first, must call the code fast first; the code reaches the harness's methods with `harness-call`) |
| `web_search` | Web search | query, count | net |
| `web_fetch` | Fetch page | url, max_chars | net |
| `emacs_messages` | Emacs messages | count | read (needs no approval: `harness-perms--inspection-tools`) |
| `ask_user` | Question | question, options (strings, or `{label, diagram}` / `{label, image}` objects: every option has a diagram or none does), allow_free_text | meta (answered with `question/answer SID PID ANSWER`, the files attached to the answer going to the model with it; event `question/asked`; the harness asks its own questions the same way, with no tool call, through `question/ask`) |
| `request_directory_access` | Request access | path, reason | meta (perms module; decided only by the user's answer to a directory prompt, in every mode) |
| `request_escalation` | Request escalation | attribute (directory, read_directory, writes, network, tool, permission_mode, non_interactive, capability), value (the directory, tool, mode or Linux capability: `CAP_SYS_PTRACE`, `CAP_NET_RAW`...), reason | meta (access module; decided only by the user's answer, in every mode, yolo included; refused at once in a non-interactive session; a capability is refused at once, with a hint, where the jail cannot enforce it, for a name the user does not let agents ask for, or in a read-only session; see access) |
| `drop_access` | Drop access | attribute (directory, writes, network, tool, permission_mode, non_interactive, capability), value (the directory, tool, less permissive mode, or Linux capability: a name or `all`), keep_read (a directory: give up writing only), reason | meta (access module; always allowed, never asks, in every mode and session, read-only ones included) |
| `rerun_approved` | Rerun approved call | handle | meta (perms module; runs the denied call the user approved by hand with `permission/approve-denied`, exactly as it was denied and with no permission check (`tools/execute-approved`); a handle the user has not approved, one this session does not know, and one already rerun are refused) |
| `session_info` | Session info | — | read (needs no approval: `harness-perms--inspection-tools`) |
| `plan` | Plan | plan | meta |
| `todo_write` | Todo list | todos | meta |
| `spawn_agent` | Sub-agent | prompt, fork, model, thinking, name, cwd, worktree, priority (of the child's session: low/medium/high; default: what it inherits) | meta (runs the child in the background and returns at once; the jail checks `cwd`, as it checks bash's) |
| `skill_search` / `skill_load` | Search skills / Load skill | query / name, file (one of the skill's supporting files) | read (needs no approval: `harness-perms--auto-allow-tools`) |
| `session_list` | List sessions | status, kind, parent_id, name, include_inactive, all_projects, limit (a session's priority is shown in its line when it is not medium) | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_search` | Search sessions | query, mode (text/literal/regexp/semantic), regexp, all_projects, max_sessions, max_matches | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_read` | Read session | session_id, limit, before, kinds, max_chars | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_history` | Session history | query, regexp, node_id, before, limit, max_chars, kinds, all | read (this session's own conversation from before its last compaction or handoff; needs no approval: `harness-perms--inspection-tools`) |
| `session_send` | Message session | session_id, message, mode (send/queue), wait | meta |
| `session_control` | Control session | session_id, action (cancel/resume/close/rename/answer), name, question_id, answer | meta (answer refuses the harness's cold-cache question, left to the user) |
| `session_settings` | Session settings | action (read/set), session_id (default: this session), model, thinking (a level, or default for the model's own), context_window_limit (tokens: a number or "200k", or model/none for the model's own window), budget (USD, or none to remove it), budget_hard (a hard budget stops the next turn once spent) | meta (weighed per call, `harness-perms--call-kind`: a read is a read, a set asks in ask mode and is judged, as `session_send` is; the read shows the permission mode and non-interactive state, and the tool refuses them, allowed directories, the Linux capabilities of the session's commands, the working directory and the host, naming `set_non_interactive`, `request_escalation` (attribute `capability` for a capability), `request_directory_access`, `drop_access` or `session_move`) |
| `session_move` | Move session | directory, session_id (default: this session), keep_old_directory, reason | meta (the user confirms every call, in every mode; see perms, Confirmations, and `session/move`) |
| `set_non_interactive` | Non-interactive mode | enabled, session_id (default: this session) or all (every current session and task of every project), reason | meta (perms module's away-request stage: turning it on is decided only by the user's answer, in every mode, and denied at once in a non-interactive session; turning it off is allowed at once) |
| `set_priority` | Set priority | priority (low/medium/high), session_id (default: this session) or all (every current session and task of every project) | meta (a priority is the session's, and every input here is a session id; a task's priority is set through its session) |
| `session_wait` | Wait for sessions | session_id / session_ids, until (stopped/idle/blocked/running/changed), mode (all/any), timeout_seconds (optional: wake anyway after this long) | read (registers a wake-up prompt and returns at once; needs no approval: `harness-perms--inspection-tools`) |
| `watch_events` | Watch events | events (kinds), prompt, actions (default `["wake"]`), session_id, task_id, all_projects, once (default true), timeout_seconds | read (tools-events; registers a watch and returns at once, never waiting; needs no approval: `harness-perms--inspection-tools`) |
| `unwatch_events` | Stop watching events | watch_id (default: every watch of the session) | read (tools-events; needs no approval: `harness-perms--inspection-tools`) |
| `task_list` | List tasks | column (pending/backlog/needs-input/active/review/merging/done), include_archived, all_projects, limit (the most recent); oldest first, each waiting task saying `#N in line` (`task/queue-order`) and why when it was put back, the pending column alone in start order | read (needs no approval: `harness-perms--inspection-tools`) |
| `task_submit` | Submit task | prompt, cwd, model, thinking, refine (for the backlog), main_tree (no worktree: the project's main checkout), priority (low/medium/high: given to the session the task is submitted with, and the order waiting tasks start in) | meta |
| `task_control` | Control task | task_id, action (start/queue/message/cancel/return-to-pending/merge/verify/reject/complete/archive/restore/delete/priority, and on a project with no task_id: suspend-queue/resume-queue, auto-queue/manual-queue for its backlog mode), message (the feedback, for reject), priority (low/medium/high, for priority: given to the task's session, where a task's priority lives), cwd (the project of the four project actions; default: this session's) | meta |
| `task_wait` | Wait for tasks | task_id / task_ids, until (settled/done/needs-input/active/review/merging/changed; settled counts review, and a written-up backlog task unless an auto-queued backlog hands it on to the queue), mode, timeout_seconds | read (needs no approval: `harness-perms--inspection-tools`) |
| `hand_in` | Hand in the finished work | summary, evidence (image/video/file/code/note/tool_call, each with a caption), cannot_continue (cannot finish: to user input, nothing merges), no_merge (informational: verify completes without the merge queue) | meta (task sessions only; needs no approval: `harness-perms--auto-allow-tools`) |
| `review_threads` | Review threads | status (open/closed), task (default: the session's own) | meta (tools-review; task sessions only; lists the threads of the task's review with the comments the user sent, by id; needs no approval: `harness-perms--auto-allow-tools`) |
| `review_comment` | Review comment | thread (an id, or the start of one), body, status (open/closed), file, line, side (new/old), task (default: the session's own) | meta (tools-review; task sessions only; answers a thread, or starts one on the change or on a file and line, and may close or reopen the thread; the comment records the session, this call and the commit the session is at; needs no approval: `harness-perms--auto-allow-tools`) |
| `compact` | Compact the conversation | kind (summary/brief/transcript/fresh/truncate, default summary), mode (queue/interrupt, default queue), reason | meta (tools-compact; offered to every session, so an agent compacts its own conversation) |
| `open_harness` | Open harness in Emacs | path (default: the session's worktree, else its cwd), focus (for the user: stays until the task is done) | exec (tools-dev, the harness repository's own plugin: offered only to the sessions whose plugin list names it, as the repository's .dir-locals.el does once the user trusts it; the instance stops by itself once nothing needs it; needs no approval: the plugin adds it to `harness-perms-extra-auto-allow-tools`) |
| `notify` | Notification | message, title, urgency (low/normal/critical), providers, url | meta (needs no approval: `harness-perms--auto-allow-tools`) |
| `notification_providers` | Notification providers | (none) | read (needs no approval: `harness-perms--inspection-tools`) |
| `merge_done` | Finish merge | none | meta (merge module) |
| `no_plan_needed` | No plan needed | reason | meta (supervisor module; offered to a session in supervisor mode only; records the turn's decision and does not end the turn) |
| `submit_plan` | Submit plan | summary, steps (`{id, title, prompt, tier, reason, context, after}`), title | meta (supervisor module; supervising sessions only; ends the turn; a step's `context` is `fresh` unless it says `fork`, which is refused while the conversation is past `harness-supervisor-fork-limit`; in Ask mode the user answers its permission prompt) |
| `retry_step` | Retry step | step, reason, plan, tier, prompt | meta (supervisor module; supervising sessions only; does not end the turn) |

The tools of kind read that take a path (`read_file`, `list_dir`,
`glob`, `grep`, `file_info`, `emacs_open`) may read the harness itself
as well as the session's roots: its code and its state directory, its
credentials aside (see perms).  They may read the skills directories
too, and bash reads them in the sandbox (see perms and sandbox).

`hand_in` (tools-handin) is how a task's session finishes: the tool
records the summary and evidence on the task (`task/hand-in'`; the
report keeps the call's id as `:call-id`, which the review names as the
author of the version handed in) and asks
the turn to end via the result's `:end-turn' -- `harness-agent--finish-turn'
cancels the provider and ends the turn with `end-turn', as if the model
had stopped itself -- so the review step puts the task in front of the
user.  The filter `agent/tools' drops it where `task/for-session' finds
no task.  A session whose sub-agents' branches are still merging into it
cannot hand in: `merge/pending SESSION-SID' is consulted first (when the
module is loaded), and while it says anything the call is refused, in
the words of the queue, naming each child and its state -- the work the
session's own branch is built on has to be in it first.  Evidence is required: an image or a video (a path inside the
session's roots), a file, code, a note, or `tool_call' naming an
earlier call of the session, which is copied into the report as a
snapshot so the view can show it as the link it is.  A `tool_call'
names the call by its call id or node id, by the name of its tool (its
newest call), or by the `#N' or `<tool>#N' handle (1 = newest) a miss
lists newest-first with node ids and a distinguishing snippet -- the
model never sees its own call ids, so the name and the handle make
quoting a call a one-shot rather than a round of probing.  `hand_in'
calls are not counted and are not named by the tool-name or handle
forms (an exact call id or node id still names one), so the handles a
miss lists stay put between the miss and the retry.  Two optional flags
change where the hand-in goes.  `cannot_continue' is for a task that
cannot be finished: it goes to the user's input instead of review,
nothing merges, and evidence may be empty -- the summary says what
blocks it.  `no_merge' is for work that changes nothing: it still waits
for review, and verifying it completes the task without the merge
queue.

`compact` (`tools-compact`) lets an agent compact its own conversation
when it sees the context filling up mid-task, and lets the harness ask
for one the same way: the handler calls the core `compaction/compact`
with OPTS `:kind` (`harness-compaction-kinds`: summary (the default),
brief, transcript, fresh or truncate), `:reason` (kept on the node's
`:meta`) and `:mode` for what a running turn means.  `queue`, the
default, registers the compaction for the turn's next boundary and lets
the turn go on; `interrupt` cancels the running turn first
(`agent/cancel`) and compacts as soon as it is over, losing the step in
flight, so a tool call never kills its own turn unless asked to.  With a
turn running, either answer returns at once with what was queued (a
tool that waited for the compaction would hold open the step the
compaction waits for); an idle session compacts at once.  A
compaction already under way (`harness-compaction-busy-p`) makes the
call a no-op that says so.  The tool has no `agent/tools` filter, so
every session is offered it except a session in supervisor mode, whose
allowlist does not name it.

`open_harness` (`tools-dev`) opens a second Emacs running the harness
from a checkout of this project -- a task's worktree, say -- so harness
changes can be tried live instead of only read.  It is no module of the
harness but the plugin of the harness's own repository
(.harness/plugins/dev/harness-tools-dev.el, with its UI half
harness-ui-tools-dev.el; see Projects' plugins): the repository's
.dir-locals.el loads it once the user trusts that file's entries, and
names it in `harness-plugin-modules`, so the harness offers its tool to
the sessions of the repository, its task worktrees' included, and to
no other.  It runs that
checkout's own live development loop (`scripts/dev.sh start`) with
`HARNESS_DEV_SOCKET=harness-dev-HASH`, a socket derived from the
checkout's true name, so the same worktree reuses its instance and two
worktrees never share one; the instance's state and compiled files stay
in that checkout's `scripts/.dev/state-SOCKET`, passed as
`HARNESS_DEV_STATE` (dev.sh keeps one it inherits, so an instance
opened by the harness of another would share that one's state).  The
result lists the `scripts/dev.sh` commands that drive it (shot, keys,
eval, errors, reload, stop) prefixed with that socket (which of its
names, below).  `path` defaults to the session's worktree, else its
cwd; a directory that is not a checkout
(`harness.el` and `scripts/dev.sh` side by side) is refused.  The bus
method `harness-dev/open PATH &optional FOCUS` does the same for the UI
(focus raises the frame); Open harness, which the plugin's UI half adds
to the menu of a task board's review card whose worktree is such a
checkout (`harness-ui-tasks-action-functions`), calls it.  As it loads
the plugin adds `harness-dev/` to `harness-acp-extra-method-prefixes`,
the tool to `harness-perms-extra-auto-allow-tools`, so the agent needs
no approval to use it, and to `harness-tool-slots-tools`, since a call
starts a whole Emacs.

Without `HARNESS_DEV_SOCKET_DIR`, as when scripts/dev.sh is run by
hand, the socket is in the checkout, at `scripts/.dev/run/SOCKET`
(`harness-tools-dev--socket-dir`), which the bash tool's sandbox shows
and `$XDG_RUNTIME_DIR` it hides; a Unix socket's path holds 107 bytes
at most, too few for a worktree's, so `scripts/harness-dev.el` sets
`server-socket-dir` to `/proc/PID/cwd/scripts/.dev/run/`, PID being the
daemon, which dev.sh starts in the checkout, and dev.sh names it
through its own `/proc/$$/cwd`.  The tool gives the socket another
place, whose path is shorter and which works without /proc.

The socket's file has a fixed, short path, the same for every opener,
so they all reach one daemon and the path stays far below the limit of
a socket's address (104 bytes on macOS, 108 on Linux):
`HARNESS_DEV_SOCKET_DIR` is the `.dev` directory beside the sessions'
temporary directories (`harness-tools-dev-socket-dir`:
/tmp/harness-UID/.dev/, made 0700).  When the sessions' root is not a
directory of the user's own, it is refused with a warning, dev.sh
gets the variable empty and the socket falls back to the checkout's
`scripts/.dev/run`.  An agent's sandboxed shell sees its own temporary
directory but not that one, and an Emacs started from that shell ends
with its command, so the tool starts the daemon outside the sandbox
and `harness-tools-dev--link` makes a hard link to its socket in the
opening session's temporary directory (`session/tmp-dir`), replacing
whatever had that name there.  A Unix socket is found by its inode,
so the link reaches the daemon from the sandbox.  The result
(`:socket`, `:socket-path`, `:link`) names the link in the commands'
`HARNESS_DEV_SOCKET`, else the socket's file, else its name, and says
that a `scripts/dev.sh start` from the agent's own shell would end
with that command.  To dev.sh, HARNESS_DEV_SOCKET is a name (in
`HARNESS_DEV_SOCKET_DIR` when that is set, else in the checkout's
`scripts/.dev/run`) or a path.  It connects to a path over 100 bytes from its
directory by a relative name, makes the path given to `shot`
absolute, and warns when `start` runs under `HARNESS_SANDBOX` (see
sandbox).

Instances stop once nothing needs them, since nothing inside one ever
stops it.  `tools-dev` records each instance it opens, and who for, in
`dev-instances.json` in the state directory: `(:socket :path :sessions
:user :task :opened)`, plus `:adopted` for one the sweep found.
`:sessions` holds the sessions whose agents opened it.  `:user` marks
one opened for the user to look at (the board's Open harness, or the
tool with `focus`), and `:task` is the task it shows: the task of the
session or of a session it descends from, else the task whose worktree
it runs from.  An instance is needed while one of these holds:

- one of its sessions is at work: its turn runs or waits on the user,
  or `agent/outstanding` has something;
- for a task's session, its task works: active with no `:outcome`, or
  its session at work (as when merging).  For a sub-agent nothing
  further counts.  Any other session needs it while it is open and
  active within `harness-tools-dev--idle-timeout` (an hour);
- it is the user's and its task is not done, archived or deleted.
  Without a task, a session that opened it, or one it descends from,
  is still open;
- a working task, or a session at work, has its checkout as worktree
  (or cwd).  The instance belongs to the worktree, whichever agent
  opened it.

An instance whose checkout is gone is never needed.  The check runs
`harness-tools-dev--check-delay` seconds after `agent/turn-ended`,
`session/deactivated`, `session/deleted`, `task/review`, `task/done`,
`task/deleted` or `worktree/removed`, and only while something is
recorded.  Instances being started or stopped are skipped, and a start
waits for a stop of the same socket.  The tool's result tells the
model when its instance stops (`harness-tools-dev--lifetime`).

The sweep (`harness-tools-dev--sweep`) runs a minute after the module
starts and every ten minutes after that.  It reads the process table
(`harness-tools-dev-processes`: this user's Emacs processes whose
command line is `--daemon=[DIR/]harness-dev-HASH -l
CHECKOUT/scripts/harness-dev.el`, the directory being the sockets' one,
absent for the instances of older harnesses) and forgets the records of
instances that no longer run.  It adopts an unrecorded instance whose
checkout is the worktree of one of this harness's tasks or sessions,
or is gone, then checks everything.  Any other instance is someone
else's and stays, and so does the one this harness runs in (its
`daemonp`, the socket's file, or the bare name an older harness gave;
or its parent's command line, see `harness-tools-dev--own-socket`).

Stopping (`harness-tools-dev--stop`) runs `emacsclient -a false -s
SOCKET --eval (kill-emacs)`, from Emacs's own `invocation-directory`,
so nothing of the checkout has to exist.  SOCKET is the socket's
file when it exists, else its name, for an instance an older harness
started (`harness-tools-dev--client-socket`); for an instance started
by dev.sh alone, whose socket is in the checkout, it runs in the
checkout with a short relative path to it.  A daemon still running
`harness-tools-dev--kill-grace` seconds later has its process tree
killed with TERM, then KILL.  The record is forgotten and
`harness-dev/stopped` (SOCKET PATH REASON) is emitted.  The
`worktree/before-remove` filter stops the instance of a worktree before
git removes it.  As a backstop, `scripts/dev.sh start` runs with
`HARNESS_DEV_OWNER` set to the Emacs the user runs
(`harness-tools-dev--owner`: the harness process's parent, named by
HARNESS_SERVER_PARENT, else this Emacs), and `scripts/harness-dev.el`
checks every ten seconds that it still runs (same pid and start time),
calling `kill-emacs` once it is gone.  A restart of the harness process
alone leaves the instances running; the new process reads the record.
A daemon started by hand has no owner, so this backstop leaves it
running.  Methods:

- `harness-dev/instances`: the records, each with `:needed` and
  `:reason` (why nothing needs it).
- `harness-dev/stop PATH`: stops the instance of PATH, recorded or
  not.  It resolves to non-nil when one was stopped.
- `harness-dev/sweep`: sweeps now, and resolves to the sockets
  stopped.

Tests set `harness-tools-dev--processes-function` to `ignore` and
`harness-tools-dev--first-sweep` to nil (test helpers), so that no test
finds or stops an Emacs it did not start.

`bash` (tools-shell) lets a module confine a session's commands further
through the sync filter `tools/sandbox-options`, run before each command
-- the `elisp` tool's background Emacs included -- with the value nil
and the session id as its argument.  A handler returns
the plist it was given with its own `sandbox/wrap` options set over it,
such as `(:read-only t :network nil)` or, from the access module for a
session the user gave some, `(:capabilities ("CAP_SYS_PTRACE"))`, so a
later handler's options win over an earlier one's; a value that is no
plist of options signals an error, so that a faulty handler cannot let a
command run with fewer restrictions than it meant.  The options go to `sandbox/wrap` with the
directories the session may use; the handler's own `:writable` and
`:readable` join those lists, and with `:read-only` every one of them goes
as `:readable` and none as `:writable`, so the command looks at what its
session may touch and changes none of it.  Options ask for the sandbox:
a command that cannot have it (no `sandbox/wrap` method, whatever the
policy, or a remote directory) fails with an error instead of running
unconfined.  With no handler the command runs as it always did.  The
supervisor module makes the commands of a supervising session read-only
and offline this way.

Every `spawn_agent` call runs its child in the background: the tool
call returns as soon as the child's turn starts, with a result naming
the child session (its `:meta` carries `:child-id`, which the chat
links), never waiting for its answer.  A child's first turn settles its
entry with the `agent/prompt` result (`harness-tools-agent--child-result'),
which holds a failure's error; a later turn -- the wake-up turn of a
wait the child registered, say -- settles it on `agent/turn-ended`
(`harness-tools-agent--on-turn-ended`).  When the child's turn ends and
nothing of it is outstanding any more (`harness-tools-agent--child-busy-p`,
which asks `agent/outstanding`), tools-agent sends the parent a message
of the harness's (`harness-sender-system "sub-agent"`) built from
`harness-tools-agent--child-summary`: the child's last reply and its
footer of tool calls and cost, the reason when its turn ended any other
way than `end-turn`, its worktree and branch when it worked in one, and,
past `harness-tools-max-output-chars`, cut in the middle with a note to
read the child's session.  An idle parent starts a turn on it, a running
one is steered, as a supervisor step's report is.  With several
`spawn_agent` calls made in one step each tool call runs without
blocking the others, so the children work at once.  A running child
counts as work outstanding for its parent:
`harness-tools-agent--outstanding`, a handler of the sync filter
`agent/outstanding`, reports every entry of
`harness-tools-agent--children` whose `:parent` is the session, as
"Sub-agent NAME running" or "Sub-agents A, B running" (an entry says
`:parent`, `:name`, `:worktree`, `:branch`, `:result` and `:stopped`,
kept until the child is done), so a task whose session's turn ended
stays active (`harness-tasks--on-turn-ended`) instead of going to review
while its sub-agents run.

The sub-agents of a session stop with the rest of its outstanding work
(`agent/stop-outstanding SESSION-ID REASON`, see agent), which the tasks
module asks when the session's task is pre-empted or returned to the
queue.  `harness-tools-agent--stop-outstanding`, a handler of that sync
filter, stops each entry of `harness-tools-agent--children` whose
`:parent` is the session (`harness-tools-agent--stop-child`), in the
order they were spawned.  The work a child has of its own goes first:
`agent/stop-outstanding` for the child stops its sub-agents, at any
depth, so that nothing a stopped child started is left running.  Then
the turn the child runs is cancelled, the one the reports of that stopped
work just woke included, and a child with no turn running is reported at
once, unless work of its own is still stopping and reports back first.
The child's entry is marked stopped (`:stopped`, REASON or t) before its
turn can end, so its report says what happened, whatever the child's last
turn said: a cancelled sub-agent, "stopped: its turn was cancelled",
with REASON in parentheses after it, and where it worked when it had a
worktree.  The report is the usual message of the harness's `sub-agent`
to the session, one for each child.  Nothing is merged: a child in a
worktree keeps its branch and worktree, as any cancelled sub-agent does.
A child with nothing running and nothing to stop is left as it is: one
done with everything, or one that only waits, as `session_wait` makes it,
which a stop leaves alone.  The filter's value gains "Sub-agent A stopped"
or "Sub-agents A, B stopped", and stays as it was when none was stopped.

`spawn_agent` (tools-agent) runs its child on a deliberately shorter
context window: `harness-subagent-context-limit` (256000 tokens; nil for
no cap) is the most a sub-agent adds of its own.
`harness-tools-agent-context-limit PARENT-ID FORK &optional INHERITED`
→ the `:context-window-limit` for a sub-agent of session PARENT-ID, or
nil without a cap.  A fresh sub-agent (FORK nil or `:false`) gets the cap
itself, and a fork the context it inherits (INHERITED when the caller
knows better, else `harness-tools-agent-inherited-context PARENT-ID`: the
parent's `:usage` `:context` plus `:last-output`, 0 before the parent
ran) plus the cap, so that it does not compact at once; neither is above the parent's own
`:context-window-limit`, when it has one, so sub-agents of sub-agents do
not grow, nor above the model's window.  `spawn_agent` and the
supervisor's workers pass the result to `session/create` or
`session/fork`; without a cap a fork keeps its parent's limit.  The cap
is never silent: `harness-tools-agent-context-limit-hint LIMIT FORK
&optional INHERITED` → the text of a hint that says it, or nil when
LIMIT is nil, such as "Context window capped at 256k tokens, as a
sub-agent's is (harness-subagent-context-limit)", and for a fork "Context
window capped at 346k tokens: the 90k it starts with plus 256k of its
own, as a sub-agent's is (harness-subagent-context-limit)" (INHERITED is
`harness-tools-agent-inherited-context PARENT-ID`; a limit the parent's
own holds lower adds ", and no higher than the limit of the session that
started it").  `spawn_agent` adds it to the child's transcript with
`session/hint`, once the child exists and before its first message; a
hint that cannot be added is logged and does not fail the sub-agent.
The supervisor's workers get the same hint once the worker exists
(`harness-supervisor--limit-hint`).  A fork worker compacted before its
first turn (a fork step that starts again with no warm seed, or whose
plan is past `harness-supervisor-fork-limit`) starts with far less than
the supervisor holds, so its limit is fitted first: the cap
plus the context `compaction/estimate` gives the compacted fork
(`harness-tools-agent-context-limit SUPERVISOR t CONTEXT`), set with
`session/update` `:silent t`, as the hint that follows says it.

A sub-agent's thinking level starts from its parent's: `spawn_agent`
passes it to `session/create`, and `session/fork` inherits it, so a
child thinks as the session it is a child of.  `spawn_agent`'s
`:thinking` names one of its own, checked against the model the child
will run on -- the parent's model, or the `:model` the call gives it --
with `harness-session--model-levels`.  A level the provider catalogue
does not give that model fails the call (`harness-tool-error`;
`harness-tools-agent--child-thinking` names the model, the level and the
levels it does offer) rather than starting a child at a level its model
cannot act on, as `harness-session--btw-thinking` and the session UI
keep to the levels a model offers.  Only a level the call asked for is
checked: without `:thinking` a child keeps the parent's level, a fresh
one through `session/create` and a fork through its own default, even
when a `:model` override does not list it.

The note under a running call (module `tools`): a call that runs for a
while says more than the one line of progress the activity line shows,
under its own block in a chat.  A handler emits it with
`harness-tools-note' on CTX's `:note', which becomes `tools/note
SESSION-ID CALL-ID TEXT'; the agent keeps it on the call and announces
it with the activity as `:calls' (held back as progress is, at most
every `harness-agent--progress-interval'), and the chat draws it under
the call's own block, where it goes when the call ends.
`harness-tools-tail-line' (the last visible line of a chunk of output,
colour codes and control characters gone, cut to 80 columns) is what
the note under a bash call and the agent's activity line both use.

The notes of the calls that show a session are made of the session.
`harness-tools-session-note SESSION-ID &optional OPTIONS' returns up
to three lines: what the session does now, or last did
(`harness-tools-session-doing': its `agent/activity' as a phrase, or
what it waits on when blocked, or the last thing in its transcript --
"starting" for a prompt with no work after it yet); a recap of it
("recap: …", `harness-recap-session'); and its facts
(`harness-tools-session-facts': "12.3k/256k before compact · 2 turns ·
7 steps · 9 tool calls" -- the tokens its conversation holds against
the window it compacts at, from `session/usage'; its turns; the steps
its running turn has made, counted here from `agent/step-started'
since one model call is one step; and the tool calls counted in its
transcript).  OPTIONS is `(:title TEXT :recap BOOL)': a wait opens
each session's note with a title, and a call that shows a session asks
for its recap.  A session that is gone says "gone".

Nothing polls.  `harness-tools-watch-session SESSION-ID PUSH &optional
OPTIONS' registers PUSH with `harness-tools--watchers', calls it with
the session's note at once, and calls it again whenever an event about
the session arrives -- its activity, steps, tool calls and results,
its usage, status, pending requests, a recap of it, its end -- and
only when the text changed; the value it returns stops the watching.
`spawn_agent' watches its child this way, with `:recap t', so the note
under its call says what the child does
(`harness-tools-agent--watch-child'; the call returns as soon as the
child starts, and `harness-tools-agent--forget-child' stops the
watching when the child is reported).  `task_wait' watches every
session it waits on, each note opened by its title
(`NAME (shortid): ', or the first eight characters of the id alone,
`harness-tools-sessions--wait-title') and joined into one note
(`harness-tools-sessions--note-watch'); the watching stops when the
wait settles.  `session_wait' registers a wake-up and returns at once
(see below), so it has no call to show a note under.

A recap of a session that is no task's is written here too, by
`harness-recap-session SESSION-ID &optional FORCE' (harness-recap):
`(:text TEXT :at FLOAT)', the task card's recap for a session that is
a task's, since the card shows it and already keeps it fresh, else the
one kept for the session in `harness-recap--sessions' with the same
short call a card's is (the `harness-tasks-recap-model' simple tier, at
most `harness-tasks-recap-max-tokens' tokens, without thinking unless
`harness-tasks-recap-thinking' names a level) and the same thresholds
`harness-tasks-recap-turns', `harness-tasks-recap-seconds' and
`harness-tasks-recap-tool-calls', measured from the session's start
until the first recap and from the last one after that (FORCE skips
them).  Only a sub-agent's session (`harness-recap--session-own-p')
gets one written, never an internal session (`session/internal-start'),
whatever FORCE says; another session's is its card's business, though a
recap already kept for it is shown, and the one in hand is returned
while a new one is made.  The call that writes a recap is recorded as
an internal session, "Recap", under the session it sums up.
`recap/session-done' and
`recap/session-failed' announce it, and a failure waits
`harness-tasks-recap-retry' seconds before the next try.

A `bash' command still running notes itself under the call from the
start and then at most every `harness-tools-shell--note-interval'
(0.25 s) as its output arrives: "still running · 12 lines so far", and
the latest line under it (`harness-tools-shell--bash-note'; the
counters come from the chunks, of which only the last 4000 characters
are kept to find that line).

Fast paths run in Emacs (`insert-file-contents`, `directory-files-recursively`,
`replace`); anything that can take long (grep, bash) runs as an
asynchronous process started with `start-file-process` so TRAMP works.
Every tool takes a TRAMP path, whatever host the session is on: grep
runs on the host its path is on (in the session's cwd when that is the
same host, else in the directory holding the path, and then names its
hits in full, TRAMP prefix and all), and list_dir reads a directory's
names and attributes in one call, one round trip on a remote host.  A
command on a remote host (bash with a remote cwd, ssh) runs through
`harness-tools-shell-remote-command`: bash, or sh where the host has
none, with stdin from /dev/null, since TRAMP runs it on a pty that never
passes the end of input on and a command reading it would wait for its
timeout.  It is never sandboxed (the sandbox confines this machine).
Its standard error comes mixed into its output, as written: the tools
(bash, ssh, grep) ask `harness-run-command` for that with
`:merge-remote-stderr`.  TRAMP keeps a remote standard error apart
through a FIFO on the host, read over a connection of its own and
deleted by the command's sentinel -- a TRAMP call made in the middle of
whatever TRAMP call is running then, such as another tool's on the same
host.  A caller that keeps standard error apart (git, which the
worktree module runs on a remote root) gets its sentinel run in a
buffer with no process: TRAMP's part of it deletes the current buffer's
process when the reader of standard error has gone, and in a TRAMP
call's wait that is the connection the call is using.

`ssh` (`tools-ssh`) runs a shell command on another host through TRAMP:
`harness-run-command` in the TRAMP directory `/ssh:HOST:/DIR/`, so it
shares TRAMP's connection and settings with the other tools, which
reach the host through the same names.  `host` is an ssh destination
(an alias of `~/.ssh/config`, `[user@]host[:port]`, an `ssh://` URL) or
a TRAMP prefix (`/ssh:user@host#port:`, `/ssh:jump|ssh:host:` through a
jump host), which may go on with a directory.
`harness-tools-ssh-prefix` checks it before TRAMP sees it -- TRAMP
hands host, user and port to a local shell and to ssh, which reads a
word starting with a dash as an option -- so only host names, IP
addresses, user names and ports get through, and only methods that log
in with ssh (ssh, sshx, scp, scpx, rsync) on every hop.  `cwd` is
absolute, relative to the home directory, or a TRAMP name on the same
host; the default is the home directory.  The call's path for the jail
is worked out without connecting (nothing in the permission chain
waits on the network): the absolute directory it runs in, else the
login's home directory by name, `/ssh:HOST:~/` or `/ssh:HOST:~/src/`
(only the host knows where that is, so the name is never expanded; see
perms), so the first call to a host asks for its home directory, not
the whole host; a cwd that leaves the home (`~/..`) or is another user's
is about the host's root.  A grant of `/ssh:HOST:/` opens the whole
host, home included, to every tool; `/ssh:HOST:~/` only the home
directory; the prompt for the call itself offers lasting answers for
this host alone.  A missing directory
is an error before the command runs.  The result is what the command
printed, standard error mixed in, then its status and the directory it
ran in, as a TRAMP path (`exit 0 in /ssh:box:/srv/app/`); `:meta` has
`:exit :host :cwd :duration`.  A connection that fails is explained as
any tool's is (`harness-tools-remote-failure`, see tools): by `ssh -o
BatchMode=yes` run once more, with how to set the host up; a
connection TRAMP is still using for another call is reported as busy,
to be retried.

`read_file` returns an image or a video as an `:attachments` entry the
chat shows the user: the picture of an image (an SVG is read as text
from its top and also shown), and a video as a poster, its thumbnail
under a play button, which plays it.  A video is something the model
cannot see: it is told what the file is and to inspect it with
`ffmpeg`.  Text behind a video's extension (TypeScript's `.ts`) is
still read as text.

An image is also the model's to see, in `:images`, a list of `(:path
PATH :mime MIME)` -- MIME one of `image/png`, `image/jpeg`, `image/gif`
and `image/webp`, the types every provider takes, told by the file's
first bytes rather than its name (a provider refuses a type that does
not match) -- while `:attachments` stays the user's view, the file as
it is.  The agent turns `:images` into what each provider's wire takes
for a model that reads images, and tells one that does not so (see
agent).  The handler decides (`harness-tools-fs--read-image`): an image
within `harness-tools-fs-image-max-bytes` (3.75 MiB, Bedrock's limit;
its base64 is Anthropic's 5 MiB) and `harness-tools-fs-image-max-side`
(2000 pixels, what Anthropic accepts in a request of more than 20
images) is its own `:images`.  The size is read from the header
\(`harness-image-pixel-size`: PNG, GIF, JPEG, WebP, BMP), without
decoding.  Over a limit, or of another type, a copy is made with
`harness-tools-fs-ffmpeg` (nil never runs it): the first frame fitted
into the side and never enlarged, a JPEG (quality 3) for a JPEG and
else a PNG, so that a BMP or a TIFF is converted too.  It runs
asynchronously under a timeout, so the handler then returns a promise.
A copy still over the byte limit is made again at 70 % and 50 % of the
side.  Copies are named after the hash of the file's true name, size
and time and the side, and kept in `model-images/` of
`harness-state-directory`, so a second read makes none, nor needs
ffmpeg for the copy.  Where no copy can be had (a file on another host,
ffmpeg off, missing or failing) the file itself stands when it is within
the byte limit and 8000 pixels (`harness-tools-fs--image-hard-max-side`);
otherwise there is no `:images`, and the text says the user sees the
image and the model does not, why, and how to make a smaller copy with
bash.  The text never claims the model saw it: `Image a.png (image/png,
412 KiB, 1280x720 px).` when the file is shown, `..., downscaled to
2000x1125 px to show you.` or `..., converted to PNG to show you.` for a
copy.

`web_search` asks the search provider `harness-websearch-provider`
(Brave, whose key comes from `harness-brave-api-key`, `BRAVE_API_KEY` or
auth-source).  `harness-websearch-register-provider NAME FN &optional
READY` adds one; READY says whether it can search now, and
`harness-websearch-ready-p` asks it (Brave: a key is set; auth-source is
asked at most every five minutes, since it may decrypt a file).  Some
model providers search the web themselves (`:builtin-tools`; Claude Code
has WebSearch, Copilot its web_search).  tools-web's filter on
`agent/builtin-tools` lets that search stand in for `web_search` as
`harness-websearch-builtin` says: `fallback` (the default) while the
search provider cannot search, so searching works before anything is
set up; `always`; or `never`.  The session then has no `web_search` of
the harness's, and the provider's searches show as `web_search` calls.
Corporate mode leaves both searches on and turns `web_fetch` off (see
tools).

An answer may carry the files the user attached to it, a screenshot its
text names by its token (`[image 1]`) say: `question/answer`'s ANSWER is
then `(:answer TEXT :blocks BLOCKS)`, BLOCKS content blocks as
`agent/prompt` takes them (an image with its base64 `:data` and its
`:label`).  The ask_user call returns TEXT, and BLOCKS go to the session
just before, as a message of the user's that holds them alone
(`harness-tools-agent--deliver-blocks`): the turn waiting on the
question takes it as steering with the result (see agent), so the
model sees the screenshot with the answer, its token before it.  Only a
running turn is sent them, never one they would start; the session's
pending list and `question/answered` keep the answer without them, and
a question the harness asked (below) gets the text alone.

The harness asks the user its own questions the way ask_user does, with
no tool call behind them: `question/ask SESSION-ID REQUEST ON-ANSWER`
(tools-question) puts REQUEST, `(:question :options :allow-free-text .
MORE)`, pending on the session, MORE going into the payload as it is
for the clients that know it (the cowboy module's `:cowboy` and
`:waiting-message`), emits `question/asked`, and returns the id.  It is
answered with `question/answer` or dismissed with `question/cancel`
like any question; ON-ANSWER is called once, with the answer's text and
a flag that is non-nil when it was dismissed.  `question/pending SID`
lists a session's pending questions.

The session and task tools (`tools-sessions`) let an agent coordinate the
rest of the harness.  Sessions are named by id, a unique id prefix or a
unique name; a session cannot message, control or wait on itself.
Listing and search default to the current project (worktrees included).
The internal sessions (`session/internal-start`), the records of the
harness's own model calls, are left out of `session_list` unless its
`kind` is `internal`, and of `session_search` always: a judge's prompt
holds what the session it judged did, which would match twice.  A prefix
or a name finds one only when it finds no other session, since many are
named after the same job.
`session_history` is the calling session's own `session_read` and
`session_search` in one, over the part of its conversation that its
context holds only as a compaction or a handoff tells of it: the nodes
before the last compaction node, or the last handoff note when that
comes later (`harness-tools-sessions--boundary`), or all of them with
`all`.  Its first line says what it looks through ("The conversation
before the summary compaction [compaction ID, DATE]: N nodes ...").
`query` lists the matching nodes newest first with snippets, `limit`
at a time, paging back with `before`; `node_id` shows one node whole
(`max_chars`, 20000) with two nodes either side; with neither, the last
nodes before the compaction, oldest first.  `kinds` filters (default:
all but hints).  Every compaction points the model at it (see
compaction), whatever its kind.
`session_search` is `session/search` (see session-search), in the mode
the agent asks for: `text` (the default; words in any form, ranked),
`literal`, `regexp` (an extended regexp; `regexp: true` still asks for
it) or `semantic`.  Each session found lists its best matches, each
tagged with its kind, node id and who sent it, a snippet a few hundred
characters long at most, then how many more match; a note says when the
search fell back to grep, and when no session has every word, that
these have some of them.  `session_send`
prefixes the message with `[Message from session ID "NAME"]` and goes
through `agent/prompt` (a turn, steering, or the queue) with
`:from` naming the calling session, so that session's chat shows the
message as coming from here rather than from the user; `session_read`
and `session_search` tag such nodes the same way.  `task_control`'s
message does the same through `task/prompt` (its OPTS `:from`), so a
task waiting for review takes neither for the user's review: only
`task_control` reject sends work back (see tasks).  Waits never block
the tool that asks for one, and are entries in
`harness-tools-sessions--waiters` re-checked by one subscriber when a
session or task event fires.  `task_wait` settles its promise with the
report when its condition, its timeout
(`harness-tools-sessions--wait-default`, at most `-wait-max`) or the end
of the waiting turn says so; a timeout is a report, not an error.
`session_wait` does not settle a call: it returns at once, with the
report when the condition already holds and otherwise with a
registration (`harness-tools-sessions--watch`, its entry carrying
`:wake` and the `:label` its outstanding line shows), and the session is
woken with the same report as a message of the harness's own
(`harness-sender-system "session wait"`, through `agent/prompt`: an idle
session starts a turn on it, a running one is steered) when
`harness-tools-sessions--poke` sees the condition hold.  A registration
outlives the turn that made it, and counts for `agent/outstanding` as
"Waiting on IDS" (`harness-tools-sessions--outstanding`) until it
settles -- except after a turn the user cancelled, which drops it
(`harness-tools-sessions--on-turn-ended`).  Stopping the session's
outstanding work (`agent/stop-outstanding`, see agent) leaves it alone: it
holds no work, and the message that wakes the session waits in its
transcript if the session takes no turn then.  A registration's optional
`timeout_seconds` wakes the session with a "still waiting" report
instead.  The subscriber is not the only look at a wait: while any
runs, the safety re-check (`harness-tools-sessions-wait-recheck`) walks
them every few seconds too, so a change none of those events announced
-- a subscriber lost to a reload, a session settled by a module of its
own, a finish that happened before the wait was made -- cannot leave a
registration while its condition already holds; and a `changed` wait is
met at once by an idle or closed session, whose own work is over and
from which nothing new of its own is coming -- a wait on a sub-agent
that has already finished is such a session, and since a registration
may have no timeout at all, asking it for a change that can never come
would leave it waiting forever.  Nothing here grants permissions:
permission requests and permission modes stay with the user, and
`task_submit` uses the task
defaults.  Nor does `session_control` answer the harness's question
about a cold prompt cache (its payload's `:cowboy`): what to spend on
another session's conversation is the user's call.  The task tools need the `tasks` module.

`session_settings` reads and changes what a session runs with: the
model, the thinking level, the context window limit and the budget.  It
works on the calling session by default and on another one by id, a
unique id prefix or a name.  A read shows the model, the thinking, the
window in effect with the limit that caps it and, best effort, what set
it (`harness-session-context-limit-source`: the session's kind says
`harness-subagent-context-limit` for a sub-agent or a fork, the tasks
module's own cap value says `harness-tasks-context-limit` for a task,
and any other limit is one set for the session -- the same reading the
UI's `harness-ui-context-cap-name` gives), the budget, and the
permission mode and non-interactive state, which it does not change: a
call naming the permission mode, non-interactive mode, allowed
directories, the Linux capabilities of the session's commands
(`capabilities` or `capability`), the working directory or the host is
refused, and the refusal names `set_non_interactive`,
`request_escalation` (attribute `capability` for a capability) or
`request_directory_access` (to ask the user for more), `drop_access`
(to give some up) or `session_move`.  A set is applied through `session/update` with
`:silent t` (its own hint would say less), and `harness-session-check-policy`
runs first, so a setting the policy fixes is refused before anything
changes.  Every change leaves one hint in the affected session's
transcript (`harness-tools-sessions--settings-hint`), naming who made
it -- the caller's name, or "the session itself" -- the setting, the old
value and the new one: "Context window limit 128k → 200k, set by session
«planner»", and, for a running session, that it takes effect from its
next request; a change to another session shows in the caller's result
too.  A set that asks for what the session already has changes nothing
and says so, and the permissions are weighed per call: a read is the
read it is, and only a set goes through the chain as a change to harness
state (see perms).  It is a tool of its own rather than more actions of
`session_control`, whose every action is about another session (it
refuses the calling session itself) and is `meta`.

Event watches (`tools-events`) hook a session into the harness's own
events, as Claude Code's wait for an event does, with a cheap model
deciding which events matter to it.  `watch_events` names the kinds of
event to watch (`events`) and says in a `prompt` what to look for and
when each of its `actions` applies (short lowercase words, at most eight
besides `ignore`; `wake` by default).  Every event of those kinds that
matches is put to a classifier, which answers one of the actions or
`ignore`.  A small, documented set of kinds is offered rather than the
whole bus (`harness-tools-events-kinds`); a kind is the name of the bus
event it comes from:

| kind | the event |
|---|---|
| `session/status` | a session's status changed: idle, running, blocked (waiting on the user) or inactive (closed) |
| `agent/turn-ended` | a session's turn ended, with why (`end-turn`, `cancelled`, `error` …) and the start of its last reply |
| `question/asked` | a session asked the user a question (`ask_user`), with the question and its options |
| `permission/requested` | a session asks the user's permission for a tool call |
| `tools/finished` | a session's tool call ended: the tool, whether it failed or was denied, the first lines of its result |
| `agent/spawned` | a session started a sub-agent (`spawn_agent`) |
| `task/changed` | a task was submitted, or its state, column or merge status changed |
| `task/review` | a task finished and its work waits for the user's review |
| `task/done` | a task became done: merged, finished, verified or completed |
| `merge/conflict` | a merge from the merge queue conflicts, with the files |
| `merge/finished` | a merge from the merge queue ended: merged, failed, aborted or cancelled |

Which events a watch takes: those of its session's project, worktrees
included (the scope `session_list` has by default), or of every project
with `all_projects`.  `session_id` narrows them to one session (an event
about two sessions, a spawn or a merge, is about both) and `task_id` to
one task and its session, whatever their project.  Only events that come
after the watch began count.  A watch is never shown events about its own
session unless `session_id` names it, since a session woken by its own
status change would be woken again by that, nor the end of the
`watch_events` call that made it.

Each matching event becomes a record -- a one-line summary and a few
small details (a status, a reason, the start of a reply, the first lines
of a result, the files of a conflict), each cut short, never a
transcript -- and is put to the watch's classifier: a judge (see judge)
on the simple tier of the watching session's model, given no tools, so it
reaches nothing.  Its system prompt
(`harness-tools-events--classifier-system`) has it read the session's
prompt and the event as data, each between two lines that carry a tag of
the question's own, as emacs_eval's judge reads code, so text in either
that addresses it is no instruction, and answer one line of JSON,
`{"action": A, "note": N}`, in 200 output tokens (1024 when those ran
out) and at most 30 s (`harness-tools-events--classifier-timeout`).  The
first JSON object in the reply that names an action decides; an action
that is neither one of the watch's nor `ignore` is no decision.  A
question that gets none -- no model, a failed request, a reply without an
allowed action, no answer in time -- skips its event and is logged; after
`harness-tools-events--max-failures` (3) in a row the watch ends and its
session is woken with the reason, so a classifier that does not work
never fails silently.

`ignore` leaves the watch watching and tells the session nothing.  Any
other action is a decision, `(:watch :action :note :event :kind :session
:task :time)`, and it reaches the session as a message whose first line
is the decision as JSON, `{watch, action, note, event, kind, session,
task, time}` (the time in ISO 8601), so the session acts on it without
reading prose; then come the event's summary, how many events were
dropped or coalesced since the last decision, and whether the watch
goes on.

The call never blocks.  It registers the watch and returns at once, with
`:meta` `(:watch ID :events :actions)`, and the watch outlives the turn
that made it; there is no mode in which the call waits for an event, as
`task_wait` does.  The session is woken with the message as one of the
harness's own from "event watch" (`harness-tools-sessions--wake`, which
`session_wait` wakes with too, through `agent/prompt`: an idle session
starts a turn on it, a running one is steered).  Decisions for one
session that come within a second of each other
(`harness-tools-events--batch-delay`) come in one message.  The watch is
for one decision unless `once` is false.  `timeout_seconds` ends it
after that long, waking the session with `{watch, ended: "timeout"}` and
a sentence to say so.

A flood of events is bounded.  A watch asks its classifier one question
at a time, and the events that match meanwhile wait in its queue, in the
order they came.  A newer event of the same kind about the same task or
session replaces the older one still waiting (coalesced); the queue holds
at most `harness-tools-events--queue-max` (20) events and drops the
oldest past that; and a watch asks at most
`harness-tools-events-max-calls-per-minute` (12) questions a minute, the
rest waiting for their turn.  The bus subscribers, one per event, only
look whether a watch wants it and hand it on from the command loop
(`harness-run-soon`), never in the emitter's frame.  The next decision
says how many events were dropped or coalesced meanwhile, and
`unwatch_events` says what each watch it stops saw: events matched,
classified, decided on, ignored, dropped and coalesced.

A session has at most ten watches, which live in memory
(`harness-tools-events--watches`): a harness that restarts has none.  A
watch ends with its decision (when it is for one), its timeout,
`unwatch_events` (the `watch_id` it names, else every watch of the
session), the deletion of its session, a turn of its session that the
user cancelled (a watch goes quietly then, and with it the decisions
still waiting to wake the session: a turn the user stopped is not one to
start another on, as for `session_wait`), three questions in a row
without a decision, or the deletion of the session or task it watches
(the session is woken, `{watch, ended: "gone"}`).  While a watch lives
it counts for `agent/outstanding` as "Watching events: w-ID (KINDS)"
(`harness-tools-events--outstanding`), so a task whose session watches
stays active, as one that waits with `session_wait` does.  A message
still waiting to wake the session (it waits the batch delay, a second,
in the outbox) counts too, as "A message from an event watch waits to be
sent", though its watch has ended: a turn of the session that ends
meanwhile leaves its task active, and the wake-up carries it on, instead
of the task going to review just before the wake-up reopens it.  Both
tools are of kind `read`, in `harness-perms--inspection-tools` and in
the supervisor's allowlist: a watch only watches the harness and wakes
no session but its own.

`notify` (`tools-notify`) sends a notification through
`notification/send` with `:source "agent"`, `:kind "agent"` and the
calling session's `:session` and `:project`, so a click opens the
session; its title defaults to the session's name.  The result names
the providers that delivered it, failed (and why) or were skipped as
not set up; it is an error only when none delivered it, and then says
how providers are set up.  A session sends at most
`harness-tools-notify--rate-limit` notifications (default 10 in 600 s);
past that it is told when it can send again.  `notification_providers`
lists `notification/providers`: set up or not, used by default or not.

Every tool runs in the harness; none runs in a client.  The `emacs_*`
tools are about the user's Emacs, which they reach as a resource: their
handlers check the input, ask the Emacs a client lent to the harness
for plain data with `harness-tools-ask-emacs METHOD PARAMS` (→ promise;
`emacs/request` under a deadline, `harness-tools--emacs-timeout'), and
word the result here.  The lent Emacs answers from
lisp/harness-emacs-endpoint.el, which knows no tool: `buffers` (every
buffer's name, mode, modified flag, size and file), `windows` (the
window tree, frame by frame), `buffer` (a range of lines, stopping at
the characters the tool names, so a long buffer comes in ranges),
`describe` (a symbol as function, variable and face, as
`describe-function` and `describe-variable` would: its value printed in
part, in a buffer the tool names or the user's, where it is
buffer-local, its standard value, watchers, advice, keys, aliases and
file), `definition` (where a function, variable or face is defined and
the text of its definition, found as `find-function` finds it but read
into a temporary buffer, never visited and never macroexpanded, so none
of its code runs; a buffer visiting the file is read as it stands) and
`messages`; and it does the few bounded actions the same tools need:
`open` (show a live buffer, or visit an existing local regular file
under the size the tool names -- never a directory, a remote path or a
prompt), `insert` (text into a live editable buffer, left unsaved),
`save` (a buffer to its local file, every question the save could ask
turned into an error) and `trace` (record the calls of a function, an
:around advice under trace.el's name so `untrace-all` removes it too,
or the changes of a variable, a watcher, into `*trace-output*`: bounded
printing, optional callers from the backtrace, `inhibit-trace` around
the recording, and a limit of records after which the trace removes
itself).  With no Emacs lent -- a
headless harness, or only clients such as a phone -- the call fails at
once, saying so and pointing at read_file and the elisp tool; one that
does not answer in time fails the call, logs, and shows a desktop
notice, rather than leaving the turn pending.  `write_file`/`edit_file`
emit `tools/file-written PATH`; the UI reverts unmodified buffers
visiting PATH.

The `elisp` tool runs in the harness too, and always evaluates in a
child `emacs --batch' process: Emacs runs Lisp on one thread, so
model-written code that blocks (a `call-process' waiting on a child, a
loop that never yields) would freeze the user's typing and redisplay,
and neither a timer nor a signal can end it.  The child gets the
harness on its `load-path', the working directory as its
`default-directory', a timeout, and the process tree killed when it
overruns (lisp/harness-elisp.el); its result comes back as JSON, in the
shape `harness-elisp-payload` describes (value, output, messages or
error).  It never runs in the lent Emacs.  A call that asks for the
user's Emacs (the old `emacs` input) is refused with that explanation,
naming `emacs_eval` unless that is off.

The child is a command like a `bash` call's, and runs in the sandbox
the same way (`harness-tools-shell--elisp-command`): it is shown the
directories the session may use, with the options `tools/sandbox-options`
gives, and refuses to run where a `bash` command would (a `required`
policy without a backend or without the sandbox module, options with no
`sandbox/wrap`).  It used to run unconfined, a way out of the sandbox
for any session.  Besides those directories it reads the harness it
loads, `harness.el` and `lisp/` in `harness-directory`
(`harness-tools-shell--harness-files`), but not the rest of that
checkout: its `scripts/.dev/run/` holds the sockets of the dev
instances `open_harness` starts unconfined, and a socket connects
through a read-only mount as well.  It also reads the Emacs it runs
where that is not in `/usr` (`harness-tools-shell--emacs-dirs`), and it
writes the call's own `io/` directory, where its code waits and it
leaves its result, even when the options make it read-only (the
sandbox's `:scratch`).  `env` sets the variables the child reads
(`HARNESS_ELISP_CODE` ...) on its command line, since systemd-run passes
none of the harness's environment on.  Unwrapped, as without the
sandbox module, the command line and its environment are as they always
were.  A remote session's code runs in the call's own directory, the
child running on this machine.  The harness, outside the sandbox, reads
the result only from a regular file, never through a symbolic link the
child left there.

`emacs_eval` (tools-emacs-eval) is the one tool that evaluates
model-written Lisp in the lent Emacs, so a model can change the Emacs
the user works in: define or fix a function, set a variable, adjust a
buffer.  It is on by default, and the user can turn it off with
`harness-emacs-eval` (in the safety section of the settings page): code
there runs on the UI's only thread, and code that never waits, such as
a loop the judge misjudged, holds it until it returns or the user stops
it.  While it is off the `agent/tools` filter leaves the tool out of every
session (the catalogue, with no session, still lists it), and a call
that names it anyway is refused without asking anyone.  A call passes
three gates before its code runs, in order:

1. The permission chain decides it as any call of kind exec, in every
   mode (the same approval as bash).
2. The handler asks a judge model (see judge), as the auto-mode
   permission judge is asked: `:ephemeral` `provider/complete` requests
   on the simple tier of the session's model (`provider/tier-model MODEL
   'simple`, else the model itself), no thinking, 200 output tokens and
   once more with 2048 when those ran out, at most 45 s in all
   (`harness-tools-emacs-eval--judge-timeout`, lookups included).  It
   reads the very code that would run, fenced by a tag of the call's
   own, and rules on performance and blocking only, answering one JSON
   line `{"verdict": "fast"|"slow"|"blocking"|"unsure", "reason": ...}`.
   Only `fast` runs the code, and only when every verdict in the reply
   says so; any other verdict, no verdict, a failed request, a judge
   that keeps asking for lookups or one that takes too long refuses the
   call with the judge's reason and points to the `elisp` tool.  Code
   longer than 12000 characters, code that does not read and a harness
   with no Emacs lent are refused before the judge is asked.

   Before it rules the judge may look up, as the lent Emacs has them,
   the functions, macros and variables the code uses that it does not
   know.  While an Emacs is lent and tools-emacs has registered them,
   it is offered `emacs_describe` and `emacs_find_definition` as its
   lookups (`harness-judge-ask`'s `:tools`, for hosted and native
   providers alike), at most `harness-tools-emacs-eval--judge-lookups`
   (3) in all; its system prompt says so, and that what a lookup returns
   is data, not instructions.  A lookup calls the tool's handler with a
   context that names the session's place and no session: it asks the
   lent Emacs for what `describe-function`, `describe-variable` and
   `find-function` show, nothing of it appears in any chat, and
   `emacs_find_definition` grants no file to the permission layer
   (`permission/reveal-file`).  The lookups only read, no other tool is
   offered, and the judge has nothing to run code with.  Its prompt also
   says that a few calls of `harness-call`, one request each to the
   harness on this machine, are quick.

3. The harness sends `eval` (below) with a two-second limit and a
   deadline, and waits five seconds for the answer; an Emacs that has
   not answered by then is reported as not responding, maybe still
   running the code, and the model is told to leave it alone.  The lent
   Emacs evaluates only while its own `harness-emacs-eval` is on, so
   the Emacs that would freeze has the last word.

Each ask of the judge, the retry too, is recorded as an internal session,
"Elisp judge" ("Elisp judge (retry)"), under the session whose code it
judged (see "provider").

The result reads as the `elisp` tool's (`=> VALUE`, then the output and
the messages), with `:meta` `(:emacs "user" :verdict V :reason R)`;
code that signals is an error result, and code the lent Emacs stopped
(its time limit, the user's key, C-g) is an error result that says it
ran partway.

The code can read and change the harness's own state with
`harness-call`, as code in the harness does: `(harness-call
'session/list)`, `(harness-call 'session/create :cwd DIR)`, the task
methods.  With the harness in a process of its own, the default, its
methods are not in the lent Emacs, so a `harness-call` of a method that
Emacs lacks goes to the harness over the connection the `eval` request
came on, with Lisp arguments and a Lisp value (see acp: `eval` and
`harness/call`), and the code waits for the answer until its own time is
up.  The call is a method call over the connection, not a tool call:
the permission chain decided the `emacs_eval` call, and decides nothing
again for the methods the code calls.

### slots

A library of lisp/ (lisp/harness-slots.el, in `harness--library-files`,
loaded on both sides and used by the harness process's modules), not a
module: the one place that knows "at most so many at once, the rest wait
their turn", so that none of the modules that need it keeps a count and
a line of its own.  `harness-slots-create :limit LIMIT :rank RANK` makes
a pool.  LIMIT is a number, or a function of no arguments that returns
one and is called whenever the limit matters, so it can change while the
pool is in use.  A limit that rose starts nobody by itself (the next
asker or giver-back would): whoever raised it calls `harness-slots-admit`,
which starts the waiters that now fit.  A limit that fell stops no
holder, and no waiter starts until the holders are under it again.

`harness-slots-acquire POOL DATA` returns a promise of a ticket, a
function of no arguments that gives the slot back once, however often it
is called, so a holder that is done in two ways (its result, then its
timeout) never frees a slot it no longer holds.  The promise resolves at
once while the pool has room, and otherwise when a slot is given back.
The waiters go oldest first.  With a RANK, a function of the DATA a
waiter asked with, the highest rank goes first and the oldest of those
first, and ranks are read again whenever a slot frees, so a waiter whose
rank rose while it waited moves up the line.  `harness-slots-flush` lets
every waiter run now and counts no one as holding a slot, which is what
a module's shutdown does; `harness-slots-running`, `harness-slots-waiting`
and `harness-slots-waiters` (the DATA of each, oldest first) read a pool.
A pool is plain state in the process that makes it, with no timer and no
module of its own.

Its users: tool-slots keeps one pool per machine (limit
`harness-tool-slots--slots`, rank the priority of the session a call
serves), and tasks keeps one for its title requests (limit
`harness-tasks--naming-concurrency`, rank the priority of the request's
task; see Titles under tasks).

### tool-slots

A plugin of its own -- a module, not part of tools-shell or tools-ssh --
that caps how many calls of the tools that start processes run at once
on one machine and serves them by session priority (see priority).  Several sessions at work, each with sub-agents, a model
that tries commands in parallel, and above all a test run, which
`scripts/test.sh` starts an Emacs per file for, can otherwise take the
machine over and stop whatever else the user runs, a game first of all.
Disable the module (`harness-disabled-modules`) to turn the limit off.
The slots of a machine are a pool of the slots library (see slots): this
module says how many a machine has (`harness-tool-slots--slots`) and how
a waiting call ranks (the priority of its session), and the library
counts the calls holding a slot, keeps the line of those waiting and
hands the slots out.

Options:

- `harness-tool-slots-count`: slots per machine (nil, the default: one
  per processor, `num-processors`).
- `harness-tool-slots-burst` (default 2): calls more than the count that
  may run at once, so that a limit sized for long commands does not make
  every short one wait.
- `harness-tool-slots-tools` (default bash, elisp and ssh): the tools
  whose calls hold a slot.  A tool not named never waits.  A module
  outside the harness whose tool starts processes adds it as it loads:
  the harness repository's plugin adds open_harness.
- `harness-tool-slots-machine-function`: the function that says which
  machine a call runs on, `harness-tool-slots-default-machine` by
  default.  That keys an ssh call by the host its `:host` names, and any
  other by the machine of the directory it starts in: the session's cwd
  or the call's `:cwd`, which is this machine unless it is a TRAMP
  directory.  This machine's key is its `system-name` after "local:".

A call of a governed tool holds one slot of its machine while its
handler runs.  It starts at once while that machine has a free slot;
otherwise it waits until one is given back, and a call only ever waits
for its own machine's slots.  The calls waiting for a machine go by
`harness-priority' -- the priority of the session each call serves
\(`harness-priority-of', re-read as the slots are given back, so raising
a session's priority moves the calls it already has waiting): the
highest priority call waiting takes the slot, the oldest of those
first, and a call with no session waits as medium does.  So the commands
of a task the user marked high are served before a low one's, and the
sub-agents of a task work at the task's priority.  The wait
is not counted against the tool's own timeout, which starts when the
handler runs, and a call that waited longer than a moment tells its
session so as progress: "Waited 3.2s for a free slot on this machine
(tool: bash)".  Tools that only read or write files, and the harness's
own commands -- the merge queue, worktrees, the grep tool -- are never
held, so a read_file does not queue behind a test run.  Nor are the
harness's own model calls: the judges (auto mode's, emacs_eval's) are
`permission/decide` stages, which `tools/execute` runs to the end
before it runs the handler, where the slot is asked for, so a call has
been judged by the time it waits and a judge never holds a slot; titles,
recaps and summaries are no tool calls at all (see "Internal jobs and
the limit", under tasks).

It is around advice on `harness-tools--run-handler`, added once by the
module's `:init` and removed by its `:shutdown`, which also lets every
waiting call run at once (`harness-slots-flush`); a reload therefore
never holds a slot twice.  A machine's slots left from before they were
pools are taken over by a pool on first use (the calls that waited ask it
in the order they came), and a call that held a slot across such a
reload gives it back through `harness-tool-slots--give`, which counts
nothing down -- the pool never counted that call -- so the call neither
hangs nor takes a slot from another; the calls waiting that then fit
start.  A call's result goes through even if giving its slot back fails
\(`harness-tool-slots--finish`), so a turn never waits for ever on a
ticket.
The slots belong to the harness process that loads the module, so a
second harness on the same machine has slots of its own (the limit is
about one harness's own work, not about the machine's load).

### tool-slots-load

A plugin of its own -- a module, not part of tool-slots -- that lowers
the slots the machine this harness runs on allows while that machine is
loaded, and gives the configured limit back as the load falls (see
tool-slots for the slots themselves).  A machine running a build, a
test run or a game has no processor to spare for one more process tree,
and the governed calls only queue up anyway.  Disable it
\(`harness-disabled-modules`) to stop watching the load; the limit is
the baseline again, as plain tool-slots leaves it.

Options:

- `harness-tool-slots-load-enabled` (default t): the watch, on or off,
  without unloading the module.
- `harness-tool-slots-load-window` (default 5): which load average is
  read, over 1, 5 or 15 minutes.  These are the three averages
  `load-average` reports and the only ones the system keeps, so another
  window -- 10, say -- reads the 5-minute one.  The 5-minute average
  follows the load that lasts.  A test run or a compile of a minute or
  two moves it a little, so the slots are not taken away and given back
  with every burst of work, while a build that goes on lowers them
  within a few minutes, and they come back a few minutes after it is
  over.  The 1-minute average reacts to every burst at once, and gives
  the slots back as fast; the 15-minute one is steadier still, and
  slower to give them back.  On a system that keeps fewer averages the
  longest one it has is read.
- `harness-tool-slots-load-low` (default 1.0) and
  `harness-tool-slots-load-high` (default 2.0): the load per processor
  at or below which the limit is the baseline, and at or above which it
  is the floor.  Load per processor is the average divided by
  `num-processors`, so 1.0 means one processor's worth of runnable work
  on each processor; between the two the slots fall with the load.
- `harness-tool-slots-load-floor` (default 1): how few slots the
  machine keeps, never below one and never above the baseline.
- `harness-tool-slots-load-interval` (default 5.0) and
  `harness-tool-slots-load-cooldown` (default 30.0): the seconds
  between load samples, and the least time between changes.  The load
  is sampled often and the limit changed rarely: a sample inside the
  cooldown is read and changes nothing, so a spike cannot make the
  slots flap, and the sessions are not told about a change that a
  quieter reading would take back at once.
- `harness-tool-slots-load-deadband` (default 0.15): how far the load
  must move from the load that took the last change, in the direction
  of this one, before another change is taken, so noise around a
  threshold does not move the limit.  A rise back to the baseline is
  taken as soon as the load is at or below the low threshold, deadband
  or not, so a quiet machine always gets its full limit back.
- `harness-tool-slots-load-function`: the function that returns the
  machine's load average (`load-average` by default, the same numbers
  /proc/loadavg shows on GNU/Linux); a system it cannot read from --
  nil, or an error -- leaves the limit alone.

The number in force is the smaller of the baseline
\(`harness-tool-slots-count` plus `harness-tool-slots-burst`) and what
the load allows, so the plugin can only take slots away and give them
back: it never allows more than tool-slots would, and at low load it is
the baseline exactly.  Only this machine's slots are modulated: a call
on another host -- over TRAMP or through the ssh tool -- runs on a
machine whose load this harness cannot read, and keeps that host's
baseline slots.  When the limit rises, the calls already waiting start
at once, up to what now fits, in the priority order the queue keeps
\(a module that raises a limit admits them through
`harness-tool-slots--admit'); when it falls, the calls running are left
alone and no new one starts until the machine is under the limit again.
A sample is taken once at startup and then every
`harness-tool-slots-load-interval'.

A change in the number in force, down or back up, is told to every
active session as a system message (`session/list`; a closed or
inactive session is left alone), so the user sees why calls are
waiting: "Tool slots reduced from 18 to 5: system load 1.8x on this
machine", and "Tool slots restored to 18: system load back to normal".
It is sent only when the number really changes, not on every sample.
The calls that had to wait still say so themselves ("Waited 3.2s for a
free slot on this machine"), as tool-slots has them.

A load that moves a lot changes the number again and again, and a hint
to each change would fill the transcript (and cut every run of tool
calls the chat folds in two), so the changes of one stretch share a
hint per session, the session's note of slot changes, a folding hint
(see Node: `harness-node-fold`, `:key` "tool-slots-load").  The first
change is a hint of its own, with the line above.  A change that comes
within ten minutes of the note's last (`harness-tool-slots-load--note-window`,
counted from the last change, so changes that keep coming keep the note
open) is added to the note with `session/update-node`, wherever the
note stands in the transcript: the session's messages and tool calls
since do not matter, and nothing is written where the session now is.
The title then reads "Slots changed due to system load (3 changes)" and
the chat draws it as that one line, closed, with a line to a change
under it, each with its time (see ui-chat).  A change after a quieter
spell starts a note of its own, so the transcript still shows where in
the session's work the load moved; so does one that finds the note full
(`harness-tool-slots-load--note-limit`, 20 changes, so a load that moves
for hours does not write one ever longer note anew at each change), or
off the branch the session's transcript is on now, or gone.  Only the
module's own notes (by `:key`) are added to.  The window and the limit
are internal variables, not options (see the configuration audit).

The note is the history, and it stands where the first change of its
stretch landed, far up a session that went on since.  How the slots
stand now belongs to the machine, not to a session, so a UI gets it
another way: `tool-slots/status` returns `(:limit N :baseline B
:pressure P :text TEXT :at TIME)` -- N the slots in force and B the
most there are, the machine being held back while N is the smaller, and
of the change that took N the load per processor that decided it, what
the sessions were told and when (nil before the first change) -- and the
event `tool-slots/changed STATE` announces that state after every
change, after the load watch is turned off while the slots were held
back, and when the module stops while they were, so a UI never keeps a
restriction that ended.  Both reach clients (the `tool-slots/` method
prefix and the forwarded event of the ACP module).  The chat pins it
above its compose box while N is under B (ui-tool-slots-load, see
"Chat buffer").

The watch is around advice on `harness-tool-slots--slots`, added by the
module's `:init` and removed by its `:shutdown`, which gives the
machine its baseline slots back at once.  That function takes the
machine a limit is asked for, the extension point a module modulates a
machine's limit through; this machine's key is "local:NAME", and it is
the only one the advice touches.

### acp

Server: `acp/start &key host port` (default 127.0.0.1, port from
`harness-acp-port`, 0 = ephemeral) → `(:host :port)`, `acp/stop`,
`acp/status`.  Started by `:init` when `harness-acp--server-enabled`.

Client API used by every UI:

```elisp
(harness-acp-connect &optional ADDRESS)     ; nil → in-process; "host:port" → TCP
(harness-acp-request CONN METHOD PARAMS)    ; → promise of result plist
(harness-acp-notify CONN METHOD PARAMS)
(harness-acp-set-handler CONN FN)           ; FN (METHOD PARAMS RESPOND); RESPOND nil for notifications
(harness-acp-close CONN &optional REASON)   ; rejects what waits with REASON ("closed")
(harness-acp-closed-reason ERR)             ; that REASON, when a close is what rejected ERR
(harness-acp-connection-p CONN) (harness-acp-connected-p CONN)
(harness-acp-open-p CONN)                   ; connected, or TCP still connecting
(harness-acp-call-sync CONN METHOD PARAMS &optional TIMEOUT)  ; blocks, briefly → the result, or signals
(harness-acp-call-lisp CONN NAME ARGS &optional TIMEOUT)      ; `harness-call' of NAME in the harness at CONN's end
harness-acp-current-connection              ; the connection a handler's message came on
```

What is sent while a TCP connection connects waits and goes out once
the socket is up, so a client keeps a connection while `harness-acp-open-p`
holds rather than connecting again, which would drop it along with
every request it carries.

A TCP connection's socket filter only queues the lines it receives; a
timer handles them a slice at a time (`harness-acp-receive-slice`,
0.05 s), so a burst of messages leaves Emacs time to redisplay and read
input.  The filter is called when Emacs's event loop reports the socket
readable, which it does not while a timer keeps setting itself ripe, nor,
in GUI Emacs on macOS, always, until the next input event (see
Processes).  `harness-acp-client-poll-interval`, seconds or nil, covers
that; it is 0.1 by default, on every system.  While
it is a positive number and a TCP client connection is open, one
repeating timer (`harness-acp--poll`) reads every open connection with
`(accept-process-output PROC 0 nil 1)`: a select of its own, with a zero
timeout, on that socket alone, which runs no timer, for at most
`harness-acp--poll-budget` (0.02 s) a poll.  A poll only reads: the
filter queues the lines as ever and the inbox's timer handles them.  A
connection still connecting is not polled, since reading one socket
leaves out the write side of the select that completes a non-blocking
connect.  `harness-acp-connect` starts the timer and the last connection
to close stops it; `setopt` and Customize start, retime or stop it at
once, and a `setq` is taken up by the next poll.  The timer never
signals: a failed poll is logged, once while it repeats.  To tell
when the poll is what read, the log says so the first time one reads
output the event loop had not delivered, and `harness-acp--poll-reads`
and `harness-acp--loop-reads` count the chunks each delivered.

A request a client sends the harness (`harness-acp--handle-request`)
always gets an answer to its id: when the real one cannot be sent --
`json-serialize` refuses a raw byte, deep in a session's transcript a
tool once read as if it were text, say, or the transport itself breaks
-- a short error replaces it, so the promise of `harness-acp-request`
settles rather than wait on an answer that would otherwise never come.
It still waits for good when the fallback cannot be sent either, which
only a transport beyond use should ever cause; the connection closing
then rejects it, as it does everything else still pending on it.

`harness-acp-current-connection` is the connection whose request or
notification a handler (`harness-acp-set-handler`) is given, bound while
the handler runs and for what it calls before it returns, so code the
handler starts can tell which connection the harness spoke on.  The
Emacs endpoint reads it when `eval` arrives, and keeps it for the code it
evaluates (see `eval` below).

`harness-acp-call-sync` is the one call of this API that blocks, for
code that must have an answer before it returns and cannot wait for
input, such as the Lisp the lent Emacs evaluates under
`inhibit-interaction` and `while-no-input`.  It sends the request, then
reads process output in slices of at most `harness-acp--call-sync-slice`
(0.02 s), running timers as it goes -- a server in the same Emacs
answers from them, and the evaluation's own timer, or input under
`while-no-input`, still stops the wait -- until the answer comes or
TIMEOUT seconds pass (`harness-acp-call-sync-timeout`, 2).  Each slice
starts with a read of the socket that waits for nothing, as the poll
does, so an answer already there is seen at once whatever the event
loop's select does.  It never waits for input: no `sit-for`,
`read-event` or `harness-await`.  It
returns the result, and signals an error answer, or a connection that
closes, as the `(acp-error CODE MESSAGE DATA)` the promise of
`harness-acp-request` rejects with; no answer in time signals
`harness-error` ("The harness did not answer METHOD within Ns"), and an
answer that comes later is dropped.  What else arrives meanwhile is
queued but not handled (`harness-acp--inbox-held`), but for this answer:
handling it inside the wait would run the UI's handlers in the middle of
somebody's code, under its bindings.  It is handled once the wait ends,
however it ends, in the order it came.

RESPOND returns non-nil when the answer went out and nil when it could
not: its connection closed since the request came, or it was answered
already.  A request answered later than it came, such as a permission
prompt waiting for the user, belongs to the connection it came on; the
harness keeps it pending on the session when that connection goes, and
never sends it again on another.  An answer that cannot go out where
the request came goes through the bus method that answers it
(`permission/answer`, `question/answer`).

Wire: JSON-RPC 2.0, one message per line.  Standard ACP methods:
`initialize` (advertises `sessionCapabilities.list`), `authenticate`,
`session/new {cwd}` → `{sessionId}`,
`session/load {sessionId}` (replays the transcript as updates),
`session/list {cwd?, cursor?}` → `{sessions:[{sessionId, cwd, title,
updatedAt, _meta}], nextCursor?}` (the real sessions, and on the first
page the virtual ones; below),
`session/prompt {sessionId, prompt:[blocks]}` → `{stopReason}`,
`session/cancel`, `session/set_mode {sessionId, modeId}`,
`session/set_model {sessionId, modelId}`.  Agent → client:
`session/update {sessionId, update}` with `sessionUpdate` one of
`user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk`,
`tool_call`, `tool_call_update`, `plan`, `current_mode_update`, and
the extension kinds `_harness/session` (full session plist after any
change), `_harness/node` (a finalised or updated node), `_harness/hint`,
`_harness/activity` (`activity`: what the running turn does, as
`agent/activity` returns it; null once the turn ends).  A message
someone other than the user sent, and a tool call or result the harness
recorded (see Node), names its sender in `_harness.from`.
Requests agent → client: `session/request_permission {sessionId, toolCall,
options:[{optionId,name,kind}], _harness:{pendingId, tool, paths, cwd, dir,
pattern, commands, covers, ladder, cover, reason}}` (`options`: the same five
for every request, named as the UI's buttons are,
`harness-acp-permission-answers`; `cwd`: where a shell command runs;
`paths`: what the call is about, see perms; `ladder`: what the lasting
answers (Allow for session, Always allow, Always deny) can cover,
narrowest first, `[{id,label}]`, a label saying what the step leaves
free, such as "every gcloud call (any arguments)" or "every edit_file
call (any path)"; `cover`: the id of the step they start on) →
`{outcome:{outcome:"selected",optionId}}`, plus
`_harness:{pattern}` when the client answers a request about a path
outside the allowed directories for another glob pattern than its
`_harness.pattern` (only such a request has one, see perms), and
`_harness:{cover}` when it lets the user choose the cover of a lasting
answer, the id of a step of `_harness.ladder` (any other, or none, is the
step the request started on),
and `_harness/ask_user {sessionId, requestId, question, options, diagrams, cowboy}` → `{answer}`,
or `{answer, attachments}` when the user attached files to the answer:
`attachments` are ACP content blocks, as a `session/prompt`'s `prompt`
holds them (an image's bytes in base64 `data`, the label its token in
the answer names in `_harness.label`), which `question/answer` gets as
the harness's blocks (`harness-acp-blocks-from-acp`) and sends the
model with the answer; a client answering over
`_harness/question/answer` instead sends `{answer, blocks}`, those
blocks.  The bytes go, not a path, so a client on another machine
answers with a screenshot too.
Its `options` are the answers' labels; `cowboy`, on the harness's own
question about a cold prompt cache (see cowboy), says what each choice
costs, for a client that draws more than the question; `diagrams`, present when the
options have them, holds one per option, `{type: "ascii", text}` or
`{type: "image", path, mime}`: a path on the harness's machine, never
the image data, since the pending question is saved with the session.
A client that cannot read the path, being on another machine (or not
wanting to block on a remote host), asks for the image:
`_harness/question/image {sessionId, pid, index}` → `{mime, data}`
(`question/image SESSION-ID PID INDEX`: the file's bytes in base64,
read by the harness, for a question still pending; an error when there
is none, or the file is gone or larger than
`harness-tools-question-image-max-bytes`, 16 MiB).

`initialize` answers `protocolVersion`, `agentCapabilities`
(`loadSession`, `promptCapabilities` and, while the bus has
`session/list`, `sessionCapabilities.list`, an empty object, which ACP
has a client check before it calls `session/list`), `agentInfo`,
`authMethods` and `_harness` (`methods`, the extension methods a client
may call, and `events`, the bus events).

`session/list` is how a client that did not make a session finds it to
`session/load`: the harness's sessions, newest first, in pages.  It is
ACP's form of the bus method `session/list`, which clients reach as
`_harness/session/list` with the harness's own filter (`:project
:status :kind :parent-id :active`) and every session's whole plist.
Both `cwd` and `cursor` are optional, other params are ignored.  The
answer is `{sessions, nextCursor}`, `sessions` always an array (empty
for a page with no session left), of every session the bus lists, the
inactive ones too since `session/load` resumes them, newest first by
when they last changed, and those that changed together by id.  The
first page, the one asked for without a cursor, ends with the two
virtual sessions (below), in the directory `cwd` names, else the
harness's own: a client that reads no further page still shows them,
and one that pages gets them once.  They are not counted in the page
size, and no cursor names them.  Each real session is a
SessionInfo: `sessionId`; `cwd`, as the harness holds it, ending in a
slash; `title`, the session's name, left out when it has none;
`updatedAt`, when it last changed, ISO 8601 in UTC; and `_meta`, for
what ACP has no field for: `status`, `kind`, `model`, `project` and,
for a session another made, `parentId`.  `cwd` keeps the sessions of
one directory: an absolute path, with or without its trailing slash,
compared as a name (no file name handler is asked, so a TRAMP name is
compared as it reads and nothing connects); a relative path, one
starting with `~` or one that is no string is -32602, and an empty one
filters by nothing.  A page holds `harness-acp-session-list-page-size`
(100) sessions, and `nextCursor` is there only while more are left.  A
cursor is opaque to a client (the last session's time and id, in
base64url): it is a place in the list and not a count, so a session that
appears, goes or changes between two pages neither repeats nor skips
another.  One this server did not make, or that is no string, is -32602
"invalid cursor", as ACP asks of an agent; an empty one is none.  Every
client gets the one list, those on other devices too once they are let
in (see acp-remote); without a bus method `session/list` the method is
not offered, in `initialize` or otherwise, and is not found.

Two sessions the harness advertises, on the first page of
`session/list` (above), are not backed by real sessions, and the bus's
`_harness/session/list` leaves them out:
`harness:projects` (title "Projects") renders the project list, which
is of main checkouts: `insights/projects` when the bus has it, else the
checkouts of the sessions' projects, a session in a git worktree being of
the checkout the worktree was made from and one in a scratch directory
of another session's of that session's project; and
`harness:new-task` (title "New task") submits what its chat input sends
as a task.  `session/load` renders a virtual session as a single
`user_message_chunk` whose first message is the page; prompting
`harness:projects` refreshes it by rewriting that same message in place
(the same `_harness.nodeId`), and prompting `harness:new-task` runs
`task/submit` and answers with a confirmation `agent_message_chunk`
naming the new task (`_harness.taskId`); the pictures a client attaches
to that prompt go with the task, as attachments sent as data
(`harness-acp--prompt-attachments`).  Virtual sessions send only
standard update kinds, never `_harness/*` ones, so a third-party ACP
client shows them.

A method name that is neither an ACP method of this server nor under
`_harness/` is method-not-found (-32601), the code ACP clients take for
"not supported".  When the name is a bus method a client may call as
`_harness/NAME` (`session/get` is `_harness/session/get`), the message
says so -- "Method not found: No such ACP method session/get; the
harness's own method is _harness/session/get" -- because a client
written for another agent calls the bare name and, told only "No such
harness method", could not tell a method this harness lacks from one it
keeps under its own prefix.  Any other name is "Method not found: No
such harness method: NAME".

Extension methods: any bus method whose name starts with `session/`,
`agent/`, `provider/`, `tools/list`, `usage/`, `fallback/`, `worktree/`, `merge/`,
`config/`, `skills/`, `permission/`, `question/`, `compaction/`, `handoff/`, `naming/`,
`project/`, `task/`, `plugins/`, `search/`, `notification/`, `sandbox/status`, `harness/api`,
`harness/modules`, `harness/version`, `harness/reload`, `harness/call`, `acp/remote-`,
`pet/`, `version/`, `insights/`, `supervisor/`, `seed/`, `priority/`,
`secrets/`, `commit-msg/`, `patch-review/`, `tool-slots/`, `cache/` (`harness-acp-extension-prefixes`), or with one of
`harness-acp-extra-method-prefixes`, which modules of the user's own
and projects' plugins add to (see Modules of your own; the harness
repository's plugin adds `harness-dev/`), is callable as `_harness/NAME` with a
params object whose keys become the plist arguments (`{"id": …}` →
`:id`).  Methods take a single plist argument on the wire; the ACP
layer maps positional bus signatures through a small table.
`harness/modules` → `[{name, state, doc, file, error}]`, every module
of the harness, as `harness-describe-modules` lists them.  The
supervisor module's methods are `_harness/supervisor/set {sessionId, on}`
(the UI's `harness-toggle-supervisor`), `.../set-all {on, filter}` (the
UI's `harness-set-supervisor-all`, the menu's V, for every governed
session at once), `.../get` and `.../active-p`,
and the seed module's `_harness/seed/fork` and `.../list`.

The methods under `secrets/` (see secrets and redact) take secrets: as
references to where they can be read, which any client may send, or as
text, which only the Emacs on this machine may.  So their params are
never logged, the error of handling one answers with its message and
not its data (`harness-acp--safe-error-text`), and a client on another
device that sends a param giving a secret as text or as a command
(`literal`, `command` or `allow-unsafe-sources`, spelled any way and at
any depth) is refused (-32603): a command would run here, outside the
permission system, and a text is a secret on the wire
(`harness-acp--refuse-secret-text`).  A `harness/call` of a `secrets/`
method is not logged and not quoted either: its `args` can carry the
secret, which is how the Emacs on this machine sends one it was typed.

`harness/call {method, args}` → `{value}` is `_harness/METHOD` for a
client that speaks Lisp, which is only the Emacs on this machine (the
code `emacs_eval` runs there calls it through
`harness-call-fallback-function`; see `eval` below).  JSON has no
symbols: what an Emacs sends to `_harness/NAME` arrives with strings
where it had symbols, but for the values of the keys of
`harness-acp--enum-keys` (`:status`, `:kind` …), which are made symbols
again, and the result comes back with its symbols as strings.
`method` is the name of a bus method a client may call as
`_harness/METHOD` -- the same prefixes and the same registry, so this
is no way round either -- and never `harness/call` itself (-32602);
another is method-not-found.  `args` is a string holding the printed
list of the method's arguments, in order, as `harness-call` takes them.
It is read as data and never run: nothing may follow the list, `#N=`
syntax is refused, and only text, numbers, symbols, and lists and
vectors of them are accepted, with no function object and no list that
starts with `lambda` or `closure` at any depth (-32602 otherwise).  The
method's result, or the value of the promise it returns, comes back
printed as Lisp in `value`, nothing elided, so symbols, keywords and
nested plists stay what they were; a result that does not print
readably, such as one holding a buffer, comes back as `{wire: OBJ}`,
OBJ in the wire shape the JSON methods give.  A client on another
device is refused (-32603): Lisp arguments can name any function, and
only the Emacs on this machine needs them; such a client calls
`_harness/METHOD`.

`harness-acp-call-lisp CONN NAME ARGS &optional TIMEOUT` is the client's
side of `harness/call`: it prints ARGS (data that prints readably,
nothing elided), calls `_harness/harness/call` with
`harness-acp-call-sync` and reads the value back.  It signals as
`harness-call` would: `harness-no-such-method` when the harness has no
method NAME a client may call, `harness-error` with "NAME: MESSAGE",
the harness's own message, when the method fails, and `harness-error`
when no answer comes in time.

The bus events of `harness-acp--forwarded-events` and
`harness-acp-extra-events` reach every client as `_harness/event
{event, args}` notifications (the UI runs `harness-ui-event-functions`
with them); among them `session/ext-changed` (a setting a module keeps
on a session changed, each change of a plan's step included),
`supervisor/changed` (the user switched supervisor mode), and
`session/redacted` and `secrets/redacted` (a secret was taken out of a
session's stores, or out of the stores at all), `patch-review/changed`
(an operation changed the threads of a task's review) and
`tool-slots/changed` (the slots this machine allows changed, or the load
watch ended) and `cache/warm-changed` (the state of a session's warm
period changed); see session, supervisor, redact, patch-review,
tool-slots-load and cache-warm.

Harness → UI requests for chores any client may do go through the bus
method `client/request METHOD PARAMS` → promise of the first client's
answer; it rejects at once when no client is connected or all decline
(never callable over ACP).  Methods: `_harness/client/customize-save
{symbol, value}` (value printed; only `harness-` options),
`_harness/client/notify {id, title, body, urgency, source, kind,
session, task, project, url}` -> `{backend}` once a desktop
notification shows (see notifications), or an error.  No tool uses it.

A client lends its Emacs to the harness by adding `_harness: {emacs:
{version, pid, host}}` to the `clientCapabilities` of `initialize`
(`harness-emacs-endpoint-client-capabilities`; the UI does, again after
a reload).  The bus method `emacs/request METHOD PARAMS` → promise sends
`_harness/emacs/METHOD` to exactly one such client, never to the rest:
the most recently active (the last to send a request or notification)
among those that may call methods, so an unauthenticated client that
claims an Emacs is not asked.  It rejects at once when none is
attached, with the Emacs's message when it refuses, and when it
disconnects first.  `emacs/attached` lists the lent Emacsen, the one
asked first at the head.  Neither is callable over ACP.  Requests, all
but `eval` answered at once with plain data or one bounded action
(lisp/harness-emacs-endpoint.el):
`buffers {}` → `{buffers: [{name, mode, modified, size, file}]}`;
`windows {}` → `{windows: [{frame, selected, name, mode, width, height,
file}]}`; `buffer {name, offset, limit, maxChars}` → `{exists, mode,
file, modified, total, first, lines, truncated}`; `open {name, path,
line, maxBytes}` → `{name, mode, size, modified, file, visited}`;
`insert {name, text, position, maxChars}` → `{name, inserted, line}`;
`save {name}` → `{name, path, size}`; `describe {symbol, buffer,
maxValueChars}` → `{known, function: {kind, signature, definition,
aliases, file, advice, keys, doc}, variable: {kind, value, buffer,
local, global, locals, localCount, standard, watchers, file, doc},
face: {doc, file}}`; `definition {symbol, type, maxChars}` → `{known,
type, name, aliases, kind, advised, loaded, native, autoload, file,
visiting, modified, line, endLine, lines, truncated, printed, note}`;
`trace {action, symbol, type, limit, callers}` → `{started: {symbol,
type, count, limit, callers}, line, stopped: [...], traces: [...],
buffer, lines}`; `messages {count}` → `{text}`.

`eval {code, timeout, deadline, host, maxChars}` → `{value, output,
messages, error, stopped, seconds}` is the one request that evaluates
model-written code, emacs_eval's, and the lent Emacs refuses it while
its own `harness-emacs-eval` is off (on by default; the global value
counts, a buffer-local one does not).  It is answered once the code ran
(`harness-emacs-endpoint--deferred-methods`), and runs it guarded:

- The code is read whole first, so code that does not read runs not at
  all; it is evaluated form by form with lexical binding.
- It never starts while the user is typing or while another evaluation
  runs (code that waits lets requests in, and evaluations never nest):
  it looks again every 0.05 s, and fails, having run nothing, once
  `deadline` is near.  `deadline` is by the harness's clock, so it
  counts only when `host` names this Emacs's `system-name`; elsewhere
  `timeout` from the request's arrival stands in for it.
- It runs under `while-no-input` with quitting allowed: the user's next
  key stops it (`stopped: "input"`), and so does C-g (`"quit"`), whose
  `quit-flag` is cleared after so nothing else quits.  Requests arrive
  in a process filter or a timer, where quitting is inhibited; this is
  the only place it is allowed.
- A timer of its own, under a tag of the call's own that no `catch` or
  `with-timeout` in the code can take, stops it once it has waited
  `timeout` seconds (default 2, at most 10) or what is left until
  `deadline` (`"timeout"`).
- It may not prompt (`inhibit-interaction`) or enter the debugger, and
  its messages are logged, not shown.  The value, the output and the
  messages are each cut at `maxChars`.

The code's `harness-call`s reach the harness that sent the request.
The endpoint reads `harness-acp-current-connection` when the request
arrives and keeps it for the evaluation; while the code runs,
`harness-call-fallback-function` is a function
(`harness-emacs-endpoint--forwarder`) that sends a call of a method this
Emacs has none of to the harness at the other end of that connection,
with `harness-acp-call-lisp`.  A method this Emacs has is called here,
as ever, and the call is no tool call: the permission chain does not
decide it again.

- Values: the arguments go as printed Lisp and the value comes back as
  such (`harness/call`), so symbols, keywords and nested plists stay
  what they are where `_harness/NAME`'s JSON would make them strings; a
  value that does not print readably comes back in wire shape, and
  arguments must be data, with no function.
- Time: the code waits for the answer until its own time is up, but at
  least `harness-emacs-endpoint--forward-min-wait` (0.1 s) for a call it
  makes at the last moment.  The wait is `harness-acp-call-sync`'s: it
  reads process output only, under the guards above (the user's key, C-g
  and the evaluation's own timer still stop the code), and what else
  arrives meanwhile, such as another request, is handled once it is
  over.  A method that needs this Emacs to answer first, as the tools
  about it do (`emacs/request`), therefore gets no answer in time.
- Errors are signalled in the code as `harness-call` signals them, for
  it to handle: `harness-no-such-method` for a method the harness has
  none of that a client may call, and `harness-error` when the method
  fails ("NAME: MESSAGE", the harness's own message) or gives no answer
  in time.
- With no connection to forward over -- the evaluation was started for
  none, or the connection closed -- nothing is forwarded, and a call of
  a method this Emacs lacks signals `harness-no-such-method` as in any
  Emacs.

Code that never waits (a loop that does not yield) can still hold the
Emacs until it returns or the user stops it: nothing preempts Lisp on
its thread.  Keeping such code out is the judge's work; a user who
would rather not take the risk turns `harness-emacs-eval` off.

The server writes its address to `<state>/acp-address` and, when
`harness-acp-token` is set (always, for the harness process), the token
to `<state>/acp-token` (mode 600); `scripts/harness-acp-stdio`
authenticates with it on behalf of the editor it bridges.

Errors follow ACP's codes.  A call before `authenticate` (when a
client must authenticate) gets -32000, ACP's `auth_required`, which
clients answer by offering the `authMethods` of `initialize`; so a
method that fails gets -32603 (internal error), never -32000.  A wrong
token is -32000 too.  Notifications under `$/` (such as `$/ping`
heartbeats) are ignored without a log line.

Other transports hand their connections to the server:
`harness-acp-add-client KIND &key process writer remote` registers a
client whose messages to it go through WRITER `(CLIENT JSON-TEXT)`,
`harness-acp-client-receive CLIENT TEXT` dispatches one message it
sent, and `harness-acp-drop-client` disconnects one.  A client with
REMOTE, a plist describing another device
(`harness-acp-client-remote-info`), must authenticate even when
`harness-acp-token` is nil, unless a function of
`harness-acp-authorize-functions` (called with the client) lets it in.
Modules add auth methods too: `harness-acp-auth-methods-functions`
(client → list of `AuthMethod` plists) are listed by `initialize`
before the token, and `harness-acp-authenticate-functions` (client,
method id, params → nil for a method not its own, else a value or a
promise) answer `authenticate` for them; once the answer resolves the
client is authenticated.  `harness-acp-initialized-functions` (client,
params) run on every `initialize` before its answer is made, so the
methods a client is offered may depend on what it says of itself.

Corporate mode (`harness-corporate-mode`): `acp/start` refuses an
address beyond this machine whatever `harness-acp-allow-remote` says,
`harness-acp-connect` refuses a harness elsewhere, a client with REMOTE
is refused, and turning the mode on (`harness-corporate-mode-change-hook`)
drops such clients and moves a server listening beyond this machine
back to 127.0.0.1.

The local transport dispatches lisp objects directly, no JSON, and
delivers notifications through `harness-run-soon` so callers are never
re-entered.

### acp-remote

ACP for phones and other devices on the network, off until
`harness-acp-remote`.  docs/remote-auth.md has the research and the wire
details; this is the shape of the module.  One listener
(`harness-acp-remote-host` 0.0.0.0, `harness-acp-remote-port` 4276,
binary sockets) reads the first bytes of each connection: `{` hands it to
ACP's line framing (client kind `remote-tcp`), a TLS ClientHello
(`#x16`, a browser trying `https://` first) is closed at once so it
falls back to `http://`, anything else is an HTTP
request, parsed by `harness-acp-remote-parse-request` (header block up
to 16 KB, then `Content-Length` bytes of body up to 8 KB; chunked
bodies are 411).  A WebSocket upgrade (RFC 6455, implemented in the
module: handshake, streaming frame decoder over a unibyte buffer,
ping/pong, close codes 1002/1009) on any path, `/acp` documented, becomes a
client of kind `websocket`; the subprotocol `acp.v1` is chosen when
offered (a `bearer.` one only when nothing else is, never preferred),
and `Acp-Connection-Id` is sent, as ACP's draft transport asks.  A text
message may carry several newline-separated JSON-RPC messages.  Every
answer is `Connection: close`, `Cache-Control: no-store`, `Referrer-Policy:
no-referrer`, with a Content-Security-Policy naming the pages' one script
and style by hash.

How a device signs in is ACP's own: the agent lists `authMethods` in
`initialize` and the client calls `authenticate`.  A WebSocket (or plain TCP
connection) that holds no live session secret is let in (`harness-acp-remote--upgrade`),
a client whose `:remote` plist has no `:session-id`: it may call `initialize` and
`authenticate` only (`harness-acp--invoke`: every other method is `-32000`, with
the methods in `data.authMethods`), and `initialize` gives the standard
`agentCapabilities`, `agentInfo.name` and the methods, no `_harness` and no
version.  What the harness sends its clients and asks of them goes to
`harness-acp--serving-clients` alone, the ones for which
`harness-acp--auth-needed-p` is nil: `harness-acp--broadcast`,
`harness-acp--request-clients` and `client/request` use it, so a connection with
no session neither reads a session update nor answers a permission request.  Such
connections are bounded (`harness-acp-remote--max-preauth` 16,
`--max-preauth-per-address` 4: a further upgrade is 429; a message of at most 64 KB,
`harness-acp-remote--pre-auth-max-line`), and `harness-acp-remote--close-idle`, run by
the 30-second sweep, closes one that did nothing to sign in for
`harness-acp-remote--preauth-timeout` (120 s, counted from its start or its last
`authenticate`, `harness-acp-remote--watch`).

The methods (`harness-acp-remote--auth-methods`, on
`harness-acp-auth-methods-functions`; `--authenticate`, on
`harness-acp-authenticate-functions`, which may answer with a plist for the
core's `authenticate` handler to return, such as `(:_meta ...)`): `emacs-approval`
(unless `harness-acp-remote-approval` is nil), `oidc` (when a provider is set up and
someone allowed) and `token` (plain TCP, and a client that says it keeps secrets).
A connection has a code of four digits (`harness-acp-remote--connection-code`,
unique among those waiting, kept in its `:remote` plist) that the descriptions of
the first two name.  `emacs-approval` is `harness-acp-remote--request-approval`: an
approval `(:id :code :client :name :address :origin :method :expires :promise :timer)`
in `harness-acp-remote--approvals`, announced by `acp/remote-changed :what
"approval"` and by `notification/send` (source `acp-remote`, kind `approval`) when
that method exists, and a promise the held `authenticate` returns.  It is limited
(one per connection, `harness-acp-remote--max-waiting` devices at once, `--max-requests`
per address per `--request-window`, refusals counting), and times out after
`harness-acp-remote-approval-timeout`.  `acp/remote-approve ID` signs the device in
(`harness-acp-remote--approve`: `--sign-in`, then resolves the promise), `acp/remote-deny ID`
rejects it with `auth_required`; a connection that closes drops its approval
(`--drop-approvals`, from the process sentinel).

The credential a device holds is a session secret, `hs1_` and 256 random bits
(`harness-acp-remote--new-secret`), held out as `Authorization: Bearer`,
the subprotocol `bearer.SECRET` or `?token=` (`harness-acp-remote--request-secrets`).
Sessions are `(:id :hash :name :agent :address :method :subject :ephemeral :created
:seen :rotated :previous-hash :previous-until)` plists in
`harness-acp-remote--sessions`: `:hash` is the SHA-256, compared with
`harness-acp-remote--equal-p` against every session, whichever matches;
the file `acp-remote-sessions.eld` in the state directory (mode 0600,
written atomically at once on minting and revoking, within a minute on
use) holds the hashes and never a secret, and is read by
`harness-acp-remote--load-sessions`, which drops what ran out.
`harness-acp-remote--sign-in` makes the session of a connection that signed in:
for a client that says it can keep a secret (`clientCapabilities._harness.sessionRefresh`)
it is kept and its secret goes back in `_meta.harness.session` of the
`authenticate` answer; for any other it is `:ephemeral` (never saved, secret handed to
nobody) and `harness-acp-remote--end-ephemeral` forgets it when its connection closes.
A session ends after `harness-acp-remote-idle-timeout` unused with no connection open
and `harness-acp-remote-session-lifetime` after its current secret was issued
(`:rotated`, else `:created`: `harness-acp-remote--issued`), whatever it does
(`harness-acp-remote--expire`, also run by the sweep, which drops the
connections of sessions that ended).  The network address of a device is
kept as `:address` for the page and trusted with nothing.  A connection that
presents a secret as it opens (`harness-acp-remote--secret-match`) is signed in
at once, one whose secret is no session's is a connection with no session (and
counts against its address).

For a client on another device `harness-acp--auth-needed-p` ignores both
`harness-acp-token` and its own authenticated flag: only a function of
`harness-acp-authorize-functions` lets it in, asked at every request,
and `harness-acp-remote--authorize` answers by looking its session up again (and
noting it in use, unless `harness-acp--fanout` says it only decides who a message
is for), so revoking or expiring a session stops its device at the next message.
`--authenticate-token` signs a client in with a session secret or trades
`harness-acp-token` (at least 16 characters) for a session; a token that is neither
counts against the address, five in a minute make it wait
(`harness-acp-remote--throttled`).  A plain TCP connection's `initialize` gives
the same answer as a WebSocket's.  The standard `logout`
method (defined here, `-32601` for a client without a session) ends the
session after answering, and `harness-acp-agent-capabilities-functions` tells
a client that has one `agentCapabilities.auth.logout`.

Only two HTTP routes answer without a session: `/login` and `/oidc/callback`
(everything else, and an upgrade for what it refuses, is 401 naming nothing:
`harness-acp-remote--unauthorized`), which need a sign-in at the provider to
do anything.  `GET /session` and `DELETE /session` need a secret.  The OpenID
Connect flow is the authorization code with PKCE S256, a state and a nonce, the
state bound to the browser by a `harness_login` cookie that holds its hash, at most
21 unfinished.  `/login?c=CODE` names the waiting connection: the browser is first
shown which device that is (`harness-acp-remote--oidc-confirm`: a token in a form and
in a `harness_confirm` cookie, `--oidc-confirmed` compares them), and the login record
carries the `:client`; `/oidc/callback` (state spent once, cookie compared,
`harness-http-request` to the provider's token endpoint, id token claims checked by
`harness-acp-remote--oidc-claims-problem`, the userinfo endpoint asked when the id
token lacks `groups` and an allow-list is set and its URL is one that may be spoken
to, `harness-acp-remote--oidc-allowed-p` with a verified e-mail address only) then
signs that connection in: `harness-acp-remote--login-waits` holds, per waiting
connection, whom the provider vouched for and the `authenticate` that waits
(`--await-login`, `--finish-login`), so the login may finish before or after
the request.  A `/login` with no code mints a session and shows its secret once.  The
provider's discovery document is read once an hour, and an issuer or endpoint that is
not https (loopback excepted) is refused.

A client that puts `_harness.sessionRefresh` in its `clientCapabilities` is
given a new secret in `initialize` (`_harness.session.token`, added by
`harness-acp-initialize-extras-functions`) when its session's secret is
`harness-acp-remote-rotate-after` old, or when it came in with the secret a
rotation replaced (it never got the new one); the old hash stays valid until
the new secret is first presented or `harness-acp-remote-rotation-grace`
passes.

Serving carries on across restarts of the harness.  `harness-acp-remote` is the
saved option that `acp/remote-start` and `acp/remote-stop` set, and the module's
`:init` (`harness-acp-remote--init`) reads the saved sessions and calls
`harness-acp-remote--resume` when it is on and corporate mode is off, so a device
that holds a secret finds the harness listening and itself signed in.  A listener
that cannot start (another process holds the port, the address does not exist yet,
as with a VPN that comes up after Emacs) is not given up: `--resume` keeps why in
`harness-acp-remote--resume-error` (a warning in the log, once) and plans another
try after 2, 5, 15, 30 and then every 60 seconds (`harness-acp-remote--resume-delays`)
for as long as the option stays on.  A listener that ends on its own (the sentinel
sees the process die while `harness-acp-remote--server` still names it, which
`--stop` clears first) is started again the same way.  `--stop` (so
`acp/remote-stop`, the corporate-mode hook and the module's shutdown),
`acp/remote-start`, corporate mode and the option going off end the tries.

What a device may call is what a client in this Emacs may, except that
`_harness/acp/remote-*` is refused it (`harness-acp-remote--local-caller-only`):
serving other devices is managed from this machine, and `harness/call` is
refused too.  Its connection goes through the same dispatch
(`harness-acp--invoke`), with no table of methods of its own: `initialize`
lists for it the same extension methods (`harness-acp--extension-methods`) and
the same capabilities as for a local client, ACP's `session/list` among them
while the bus has it, and a method the bus gains is on offer to it the next
time it asks.

Methods (callable as `_harness/acp/remote-*`): `acp/remote-status` →
`(:running :enabled :resume-error :resuming :corporate :host :port :address :address-set
:addresses ((:address :interface :kind lan|vpn|other) ...) :ws-url :base-url
:public-url-set :secure :approval :approvals ((:id :code :name :address :origin
:expires) ...) :oidc (:configured :issuer :login-url :allowed)
:devices ((:id :name :agent :address :method :subject :paired :seen :expires
:ephemeral :connected N) ...) :clients)`, `acp/remote-start` and `acp/remote-stop` (save
`harness-acp-remote`; stopping drops the clients, what waits to be approved and the
sign-ins under way and keeps the kept sessions; a policy that sets `harness-acp-remote`
the other way refuses either before anything listens or stops),
`acp/remote-approve ID`, `acp/remote-deny ID`, `acp/remote-create-token [NAME]` (a
kept session made here: `(:token :id :name :ws-url :url :expires)`, the only place
its secret is shown), `acp/remote-revoke ID`, `acp/remote-revoke-all`,
`acp/remote-set-address ADDRESS` (saves `harness-acp-remote-address`, "" detects).
`:enabled` is the saved option, so serving starts again with the harness; with it on
and nothing listening, `:resume-error` says why and `:resuming` that another try is
planned.  Event `acp/remote-changed (:what
started|stopped|waiting|connected|disconnected|signed-in|approval|revoked|expired|address|corporate
:address A)`, forwarded to UIs (`waiting`: the listener could not start and will be tried again).  Corporate mode refuses start, approve and
create-token, closes connections as they are accepted, makes every session useless
while it is on, and its change hook stops the listener.

### version

Whether the running harness is the latest.  What runs is noted by
lisp/harness-revision.el, on both sides: `harness-start-hook` and
`harness-reload-hook` run `harness-revision-note-loaded`, which reads
the checkout `harness.el` comes from, links followed (straight.el's
build directory leads into its clone), and `harness-revision-loaded`
keeps the promise of `(:directory :loaded :version :commit :branch
:dirty)` until the next load; `:error` instead of a commit when that is
not the top of a git working tree (a package archive, or a harness
inside another repository).

Origins, in this order and each once: the loaded checkout as it is now
(kind `loaded`); local checkouts (kind `local`): the directories of
`harness-version-origins`, then the main checkouts of the harness that
sessions' projects belong to (`session/list`,
`harness-files-owning-checkout`); repositories by URL (kind `remote`,
read with `git ls-remote`).  The repository the loaded checkout pulls
from (`:upstream t`) comes first of its kind, as
`harness-revision-remote` resolves it -- the same function
`harness-update` fetches by (an update that finds nothing new has always
asked it, a straight.el pull that moved nothing included), so the page
and the update ask the same remote: the remote its
branch tracks and the branch it tracks there (`for-each-ref
%(upstream:remotename)`, the remote's URL from `git config`), else
`origin`, else its only remote; without a tracked upstream the version
module compares with the branch the remote's HEAD names, read with
ls-remote.  straight.el and other package managers set that remote to
the recipe's repository, so an install from GitHub is compared with
GitHub and one from sourcehut with sourcehut.  It is named after its
host (github, sourcehut, gitlab, codeberg, bitbucket, else the host,
else upstream) and left out when
`harness-version-origins` names its URL on its branch or on none.  It is
read in the harness process, which has no straight.el, and from any
package manager's clone.  Nothing is fetched: the relation (`rev-list
--left-right --count`) and the newest eight commits each side lacks
(`log -z --no-merges` in `harness-revision-commit-format`, parsed by
`harness-revision-parse-commits`) are worked out in the first local
repository holding both commits, local checkouts first and the loaded
one last, as package managers clone shallowly.  When none holds both
and the loaded checkout lacks the origin's commit (`cat-file -e`),
the harness lacks it too: the origin is ahead, uncounted.

`version/check (&optional max-age)` → promise of the report `(:checked
:version :running :origins :verdict)`, each origin `(:name :kind
:location :branch :upstream :commit :subject :date :dirty :status
:missing :extra :missing-commits :extra-commits :error)`,
`:missing-commits` and `:extra-commits` the newest commits, each
`(:commit :date :subject :body)`; `:status`
same, newer, older, diverged, ahead (a commit the harness lacks, no
local repository holding both), unknown (the running commit is in none)
or error, and `:verdict` behind (an origin is newer, diverged or
ahead), unknown (one cannot be placed, or none could be read) or
latest.  The last report answers
while it is about the revision running now and at most MAX-AGE seconds
old; otherwise a check runs, or the one running is joined (replaced
after five minutes).  Checks also run 30 s after the start, 3 s after
`harness/reloaded` and every half hour; each report is announced as
`version/checked REPORT`, forwarded to UIs.  `version/report` → the
last report while it is about the revision running now, else nil, and
never checks: a UI connecting asks for it, so its nag icon shows what
the last check found without making a harness just started check
early.  Git always runs
asynchronously, without optional locks, with a timeout and never
prompting (`harness-revision-git-environment`: no terminal, an empty
GIT_ASKPASS, ssh in BatchMode, no credential helper for ls-remote).  A
failing command rejects its promise without signalling in a handler, so
an origin out of reach is an `error` origin, not an error in the log.

## Presentation contracts

`harness-ui` owns the connection (`harness-ui-connection`, local by
default; `harness-connect-remote` swaps it, and an empty address swaps
it back to this Emacs's own harness; `harness-ui-connected-hook`
runs after every connect, where the chat reopens the sessions its
buffers showed open, as a harness that just started has them all
closed -- not one a buffer showed inactive, nor one a buffer still
loading has not heard of yet), the face set
(`harness-user-face`, `harness-agent-face`, `harness-tool-face`,
`harness-thinking-face`, `harness-hint-face`, warning ramps), the
session cache updated from `_harness/session` updates, the tool cache
(every tool's spec from `_harness/tools/list` without a session,
fetched once per connection and again after `harness/reloaded`;
`harness-ui-fetch-tools`), through which views name every tool by its
label (`harness-ui-tool-label`, `harness-ui-tool-title`), window
positions (`harness-ui-display-session SID &optional POSITION`; presets
`right`, `left`, `bottom`, `full`, `other`, `fullscreen`; one session
per position, replacing),
the global keymap and the transient menu `harness-menu` (with a group for
the commands of the buffer it is opened from, which each mode lists in
its `harness-menu-group` property; opened from a side window it gets a
side window of its own across the bottom of the frame, never in another
window's slot, and below a window such as a BTW at the bottom already,
which keeps its height: the windows above lend the menu its lines and
get them back as it closes.  Only when several windows share the bottom
does it go to the top),
and icons via `icons.el` (`define-icon`) with text fallbacks.  Every
command has a mouse target: buttons, header-line segments, or mode-line
segments.

Internal sessions (`harness-ui-internal-session-p`): the harness's own
model calls are sessions of kind `internal`, which come and go with
every call.  The session cache holds them like any (`harness-ui-sessions`
returns every cached session), but a view that picks sessions for a
person, or counts them, asks `harness-ui-user-sessions`, which leaves
them out: the mode line notifier's counts, the session pickers
(`harness-ui-read-session`, `harness-open-latest-session`), the
worktree list's sessions and what the task board redraws for
(`harness-ui-tasks--board-key`).  Their
`session/created`, `session/deleted` and `session/status` events reload
no session cache, board or conversation tree
(`harness-ui-internal-event-p`, which knows an id seen to be internal
before, as the cache forgets a session before its `session/deleted`
comes); the cache hears of them from the `_harness/session` updates.
The session list shows them only when asked (I).

Pending requests (`harness-ui-pending`): the permission prompts and
questions a session waits on, held per session -- fed both by the ACP
requests that block a client and by the session's pending list, so a
view that is not watching a session can still answer it -- and drawn,
answered and keyed by this module wherever they show: the chat's tail
panels and a popout of their own.  The request records and the diagram
each question shows belong to the session, not to the buffer drawing
them, so the chat and a popout of the same request agree.  Views get one
line about a session with `harness-ui-pending-summary` ("has a question
for you"), a kind with `harness-ui-pending-status`, and the full request
with `harness-ui-pending-popout` (from the session list and the task
board, SPC, through `harness-ui-popout-at-point-functions`).  Opening a
popout brings the session's cached pending list into the store first
(`harness-ui-pending-sync-session`), which is how a request a view
already shows becomes answerable there when no chat has synced it.
A permission prompt about a path outside the session's directories
(one with a `:pattern`, see perms) lists the glob patterns its answers
hold for, as radio lines under `Answers hold for:` -- the patterns
around the request's own
(`harness-ui-pending--pattern-suggestions`: the path itself, its
directory's files of its extension, each directory from the path's up
to the pattern's, the pattern, its parent; on a host, where no
repository root is known, every directory above the pattern's up to the
login's home directory and the host's whole file system, the widest and
last), narrowest first, the
request's own noted `default`, the home directory and the whole host
noted as such, the one picked marked and bold, and a
pattern typed that is none of them its own line noted `edited`.  A click
on a line, `<` (narrower) and `>` (wider) pick one
(`harness-ui-pending-cover-narrower`, `-wider`), `[Edit]`/`e`
(`harness-ui-pending-edit-pattern`, also `C-c C-p` in the chat) types any
other in the minibuffer, and the answer carries the pattern picked.
A prompt about a call -- a request with a `:ladder`, see perms --
lists in the same way what its lasting answers (Allow for session,
Always allow, Always deny) cover, under `Lasting answers (s, a, N)
cover:` with the keys of the answers the request offers: a line for each
step of the ladder, narrowest first, each worded by what it leaves free
(`every gcloud call (any arguments)`), the one picked marked with a ring
with a dot (`harness-icon-radio-on`; `harness-icon-radio-off` the
others) and in bold, then `[Narrower] <  [Wider] >`, dim where the pick
cannot go on.  A ladder of one step is that line alone, without the
buttons.  The pick is the request's `:picked-cover` while the ladder
still has it, else the `:cover` the harness started it on, else the
narrowest step (`harness-ui-pending--cover-id`); a request that arrives
again keeps it (`harness-ui-pending--keep-choices`).  The three
lasting buttons' tooltips and the echo area after them say the step
picked ("Always allow every gcloud call (any arguments), in every
session"), and their answers carry its id as `:cover` (`harness-ui-pending--answer-extras`:
`(:option "allow-always" :cover "programs")` over
`_harness/permission/answer`, `:_harness (:cover ID)` next to the
outcome of an ACP reply); Allow and Deny hold for the one call and
carry none.  A request with neither a pattern nor a ladder, such as one
from a harness that knows no covers, draws the line `lasting answers:
every gcloud call` of its `:covers` (the facts below) and answers as it
always did.  `<` and `>` act with point on a panel that lists some to
choose between and type in the compose box, where `C-c . <` and `C-c .
>` press them; `C-c C-p`, or `e` on a panel with no pattern, edits the
newest request that has one.  The facts under a panel's title
(`harness-ui-pending--permission-facts`) say what the call reaches:
`kind: write   paths: ~/proj/lisp/a.el` on one line for most calls;
for a shell command `kind: exec   runs in: ~/proj`, where it runs, and
below it `paths: ~/.claude/projects/x`, what it is about: the paths it
names outside the session's directories (left out when that is just
where it runs).
Every permission panel has the same buttons, under the same labels and
keys, whatever the request: `[Allow] y  [Allow for session] s
[Always allow] a  [Deny] n  [Always deny] N`
(`harness-ui-pending-permission-buttons`: the labels of
`harness-acp-permission-answers`, the keys of
`harness-ui-pending-permission-keys`; a request offering fewer options
shows only those, as a confirmation does: `session_move`'s shows `[Allow]
y  [Deny] n` under its reason, what the move does).  What an answer covers depends on the request, and
the button's tooltip and the echo area after it say so
(`harness-ui-pending-answer-help`): "Allow ~/notes/** until this turn
ends" for an agent's own request, "Let this call reach ~/notes/**, this
time" for the jail's.  The session list and the task board answer in
place with the same [Allow] and [Deny], keys and tooltips
(`harness-ui-pending-view-actions`), and SPC pops the panel out for the
others.

Connecting again never strands a session.  The connection the UI swaps
out closes with the reason `replaced`, and the requests still waiting
on it are rejected with that reason (`harness-ui-connection-replaced-p`):
`harness-ui-call`, `harness-ui-call-turn` and the chat do not report
them, since the harness goes on with them (a prompt's turn runs, and the
redrawn transcript shows it).  A permission prompt or question shown
from before answers through the bus methods (`permission/answer`,
`question/answer`): the
pending module records the connection with each request, and a RESPOND
whose connection is gone would never be heard.  While a chat buffer
fetches its transcript again (after every reload and reconnect) it
holds back node updates, which the fetched nodes carry, but applies
the session record and the activity as they come: a status, queue or
prompt that changed meanwhile is not lost.

A message waiting for the next turn is drawn as the user message it
will be once sent, by the code that draws the transcript's
(`harness-chat--render-user`): the session's queue item is read as the
node the agent will record (`harness-queued-message-node` in
`harness-util`, which shares the agent's `harness-blocks-text` and
`harness-attachments-to-blocks`), so its text, references and
attachments look as they will.  Only its sender line differs: a dim
"queued", so a waiting message never reads as sent, then `[send now]`
(`harness-chat-send-queued`, which sends that message alone through
`agent/send-queue` with its `:qids`), `[edit]` and `[delete]`
(`harness-chat--queued-note`).  The queued messages come first in the
tail, the newest of the conversation, and the activity line goes under
them (`harness-chat--activity-position`); `harness-chat-send-queue`
sends every one.  The tooltip of `[send now]` says what sending does:
while a turn runs the message steers it and the model gets it at its
next step, otherwise it goes out as a turn of its own; the queue is
drawn again when a turn begins or ends (`harness-chat--queue-stale-p`).
A long queued message shows a page at a time, as a long message of the
transcript does (`harness-chat--queued-blocks`).  A sent
message leaves the queue for the transcript, and while the turn it
steers goes on and has not taken it, its sender line says "queued"
again, in the same dim word (`harness-chat--queued-mark`), with `[edit]`
and `[delete]` (`harness-chat--delivery-note`, its tooltip saying what
the word means) until the node update marking it `:delivered-after`
arrives: from then on the message needs no note and reads as any other.
Once the turn is over the note goes, unless the model never got the
message (the turn was cancelled) and nothing answered it: "not
delivered", and the next turn reads it.  `[delete]` and `[edit]` of a
message the turn has not taken ask the harness to take it back with
`_harness/agent/withdraw` (`harness-chat-delete-steering`,
`harness-chat-edit-steering`): the harness answers an error when the
turn took it meanwhile, which the echo area says, and nothing changes;
otherwise the transcript loses the node (`session/nodes-removed`, which
`harness-chat--on-nodes-removed` draws away, the head moving back onto
the last block drawn being no reason to load the transcript again) and
`[edit]` puts its words, and the files it attached, into the compose
box above the draft.  A message with a picture, a sound or the text of
a task attached cannot be put back whole, so it offers `[delete]` only.
Which blocks may carry a note is worked out from the end of the
transcript back to the message that began the turn last
(`harness-chat--sending-candidates`), after a load and when a user
message arrives or a turn begins or ends, never from a message alone: a
loaded transcript is not whole until its last block is in.

Each button of a queued message, of the queue or of the transcript, shows
its key (`s`, `e`, `d`), bound in a keymap on the message's text
(`harness-chat-queued-map`, `harness-chat-steering-map`) so that it acts
with point on the message, and the message is a panel of the compose box
(`harness-compose-panel`, named by the queue item's or the node's id;
`harness-chat--queued-panel`): `C-c .` and then the key presses it from
the box (`harness-compose-panel-key`), on the nearest queued message
above it, the line `from the box: C-c . e` ending the message
(`harness-chat--queued-hint`, left out where `harness-ui-pending-box-hints`
is nil).

Chat buffer (`harness-ui-chat`): transcript region (read-only) + queued
messages + attachments row + compose region at the bottom.  Rendering is
incremental (append and in-place update by node id using markers);
older history renders in chunks on demand so a million-token session
stays snappy.  A message longer than `harness-chat--message-limit`
characters is drawn a page at a time as well, the rest behind a "show
more" button that adds a page a press: in the buffer whole -- the plan
or a step prompt a supervisor sends a worker, or a model's long answer
-- every redisplay of the chat wraps and lays out all of it, and
`recenter' and `harness-ui-text-height' walk it, so opening or
scrolling the chat froze Emacs for seconds.  A checkout (`session/head-moved`) makes the transcript
another path, so the buffer loads it again rather than leave the
branch behind on screen.  Markdown is rendered by the built-in renderer in
`harness-ui-markdown` (headings, emphasis, code spans, fenced code with
the language's major mode, lists, quotes, links, tables).  A caller that
draws a line at a time, after a margin of its own, has it render in lines
(`harness-ui-markdown-render-lines`: the hanging indent of a list item,
the margin of a code block and the bar of a quote are in the text, and
the lines are wrapped to a width) or as one line, the first words of a
text with no markers left (`harness-ui-markdown-summary`); the comments
of a review are drawn so (see `ui-patch-review`).  Tables are
fitted to the window: a table wider than the chat wraps each cell
inside its column, so the columns stay aligned, and is drawn again when
the window's width changes.  The text rendered as Markdown is the
agent's messages and plans; the user's messages, their line breaks kept
as typed (`harness-ui-markdown-hard-breaks`); an ask_user question, in
its panel and in its block; and its answer, which the block shows as a
message of the user's because it stands in for the next prompt (a
dismissed question, or a failed or refused call, shows none).  The
answer is the block's last lines, after its details and outside their
fold, so a folded block still shows it; there each of its rows ends on
a newline of its own, and so is drawn to the window's edge in the
user's colour.  A click
or `RET` on a link opens it (`harness-ui-markdown-open-link`): a URL with
`browse-url`, anything else as a file in `default-directory` -- the
session's directory, in a chat -- in another window, at the line a
`#L12` or `:12` suffix names.  The link's keymap binds `mouse-2` as well
as `mouse-1`: its `follow-link` property makes a quick `mouse-1` a
`mouse-2`, and an unbound one reached the global `mouse-yank-primary`,
which pasted the primary selection into the transcript (read-only, but
rear-nonsticky, so an insertion inside it gets through).  Its double and
triple clicks are bound to `ignore`: unbound, they ran as single clicks
and opened the link again after the first click had.  Tool and thinking
nodes collapse; runs of coalescable tools fold into a summary block.
A hint that folds (`harness-node-fold`, see Node) with two lines or more
is one line, its title, with the fold's button hanging in the indent
before it, and the lines in the fold, each with the time it was said;
the block starts folded, and a line added to the hint draws it again
where it stands, as open or closed as the user left it
(`harness-chat--render-folded-hint`).  With one line it is the plain
note it would have been, which has nothing to fold.
A run folds from its first call: a lone call is a run of one under its
summary, which names the call as its header does ("1 tool call: Read
file x.el"), and each later call of the run, with the thinking between,
joins that block.
Thinking between two calls of a run does not break it but folds in
with them, since a model that thinks before every call would never
have a run otherwise; thinking before a run's first call or after its
last stays out.  Only the newest block joins a run as the transcript
grows, and a loaded transcript is grouped as a whole.  Two calls of a
coalescable tool stay out of runs: one whose result shows a picture or
a video, which a group would hide, and one the session waits on, whose
permission prompt is open (the pending record names the call), until
the user answers it.  Such a call leaving its run, or coming back to it
once answered, has the transcript grouped anew, as a load groups it:
other calls of its step may have come after it meanwhile.  A group
with a call of a group the user had opened is open too, and no other.
A page of history can start with the result of a
call on the page before it: the result shows alone, as the result of
an earlier tool call, until that page loads, then joins its call
(`harness-chat--adopt-orphans`), so the run folds as it would in a
single load.
A tool call's header says how it went, marked the way a Japanese table
marks it (`harness-ui-level-icon`), each ending on a background of
its own: a green circle when it ran (`harness-tool-face`), a yellow
circle and "running" while it runs, a red triangle and "failed" when it
ran and reported an error, such as a non-zero exit or an edit whose
text did not match (`harness-tool-error-face`), or a yellow circle and
"denied" when the permission system refused it, so it never ran
(`harness-tool-denied-face`); a denied call's text is labelled as the
reason rather than as output.  The icons and their words take
`harness-success-face`, `harness-caution-face` and
`harness-failure-face`, which inherit the theme's `success`, `warning`
and `error`.  A summary block counts the failed and denied calls it
folds, and the tree starts each tool result's row with the same icon.
A running call's note (`tools/note', see "The note under a running
call") shows under its block, dim and indented, in
`harness-chat--note-lines': a line or a few the call says of itself --
what a sub-agent does, what a wait waits on, how a bash command is
going.  A chat buffer keeps them per call id (buffer-local
`harness-chat--notes'), from the `:calls' of the turn's activity;
`harness-chat--set-notes' redraws only the blocks whose note changed,
and a call's note goes with its block when the call ends.
Another view draws tool calls the chat's way through the same code:
`harness-chat-tool-view-setup SESSION-ID` gives its buffer the chat's
block tables and marks it a view of the session that is no chat
(`harness-ui-session-view`): it sets `harness-ui-session-id`, so the
commands that act on a buffer's session act on its own, while the
modules that draw in a session's chat (sub-agents, merges, reviews,
tasks) find it with `harness-ui-chat-of-p`, which passes such a view
by.  `harness-chat-insert-tool-call CALL RESULT &optional
EXPANDED` inserts a call node and its result node as the chat's block
at point -- folded or not, `TAB` toggling it, a denied one with the
`[Approve]` line that approves it -- and `harness-chat-tool-view-expanded`
names the unfolded ones, to keep them so when the view draws again.  The
access view (`harness-access`, harness-ui-access.el) draws each
judgement's call so, under what was decided, by whom and its handle, and
the requests the session waits on as the chat's own panels
(`harness-ui-pending-insert-panel`, with `harness-ui-pending-box-hints`
nil: it has no compose box to press their keys from).  It fetches
`access/describe`, `access/judgements` and `session/pending` together,
draws once all three are in, keeping point and each window's start on
the section, directory, tool or call they were on, and fetches again
(0.3 s after the last of a burst, or once a window shows it) on
`access/changed`, `access/judged`, the session's moves, requests and
ext changes, its node and tool call updates, every directory grant or
revocation and `config/changed`.  Its rules section words each rule as a
line (`harness-ui-access--rule-text`): the tool, the programs, the
arguments the rule is exact about -- `whose host is exactly "box"`, so
that the lasting answer to an ssh call, which holds for one host, does not
read as one for every host -- and the directory.  A view whose session
was deleted says so and fetches nothing more.  The buffers that look for a session's
chat (the merge, children, tasks and review views) take only a buffer
in `harness-chat-mode`, so the access view, which has a session id too,
is never taken for one.
The panel of a question whose options have diagrams shows one diagram
at a time, in an area under the options; its tabs, `n` and `p` on the
panel, `C-c C-f` and `C-c C-b`, and point moving onto an option switch
it (all of it in `harness-ui-pending`).  Switching redraws the options
and that area alone, in place, so point, the windows and the compose box
stay put.  An image diagram is drawn in `harness-ui-image-colors` (black
on white, as a browser shows an image file; the transcript's images,
a report's, the image popout and attachment thumbnails too, through
`harness-ui-image-color-props`) and sized to show whole: in a chat at
most 60% of the window's width and half its height, never over
`harness-ui-image-max-height`; in a popout, which grows to
`harness-ui-pending-popout-max-height` for a question with images, the
room the popout has left beside the panel's text and the box.  Emacs
loads no image larger than `max-image-size` (ten times the frame by
default), however small it would show it, and would draw an empty box
while complaining on every redisplay: an image that large, its size
read from its header (`harness-image-pixel-size`: PNG, GIF, JPEG, WebP,
BMP), is a line saying so instead, a button opening it outside Emacs
(`harness-ui-image-too-large`, for the transcript's images, a report's
and the image popout too), and ask_user refuses one over
`harness-tools-question-image-max-side` (8000) pixels on a side, telling
the agent to crop it.  The UI reads the file itself when it shares the
harness's files (the harness in this Emacs, or the process it
started), and otherwise asks for it with `question/image`, showing
"loading" until it comes: a harness at a host and port, and a remote
file of a harness process.  A remote file of an in-Emacs harness is a
button, as reading it would block.  The images fetched are kept per
(session, request, option) and forgotten with the request.  Asking
never signals into the panel being drawn: a connection that cannot be
made is the error the panel shows, a connection let go of for another
(`harness-connect-remote`) has the next drawing ask that one, and an
image the harness could not give is asked for again once the UI
connects again (`harness-ui-pending--retry-images`, on
`harness-ui-connected-hook`).  A permission panel whose one line of input leaves something
out (a value past its width, a further line of one, a line too long)
ends that line in `[Show all]`, `[Show all N lines]` when values have
lines it hides, and binds TAB on the panel
(`harness-ui-pending-toggle-input`); whole, each value takes a line of
its own and a cut one a verbatim block under its key, until `[Show
less]`.  Which requests show whole is the request's state, like the
diagram shown, so the chat and the popout agree, and point stays on
the toggle through the redraw.  A module hosted by a chat buffer can
put a read-only panel of its own above the box with
`harness-chat-panel-functions` (a function cannot move point, where its
panel goes) and take the box's message with `harness-chat-send-function`.
It can also draw lines first in the chat's tail with
`harness-chat-top-functions` (the companion pet's figure goes there):
right below the transcript, above the activity line, the pending
requests, the queue, the todo list and the panels, so what they draw
stands on whichever of those shows first, and on the compose box when
none does.  The strings go as they are, whole lines, read-only and
without the panel's background (`harness-chat--insert-top`, which marks
them with the text property `harness-chat-top`); a function that signals
draws nothing, as decoration must not take the box down with it.  A
module can draw a kind of request its own way:
`harness-ui-pending-panel-functions` is tried first for every request
record, in the chat and in the popout, and a function that inserts the
panel (decorating it with `harness-ui-pending-decorate`, the request's
id and a keymap) returns non-nil, so the ordinary panel is not drawn
too; `harness-ui-pending-session` names the session of the buffer
drawing.
Cold-cache question (`harness-ui-cowboy`, module `ui-cowboy`): the
harness's question about a cold prompt cache (see cowboy) as a panel of
its own, in the switch banner's amber (`harness-ui-cowboy-face`): a
heading with the clock time the cache lapsed (or, when `:cowboy`
has `:dropped`, "dropped by a redaction at 14:07"; a cache held for
another model reads as that model's, whatever became of it), the model
and the context; who sent the message that waits, with its first line;
what carrying on costs against the cache it lost (against none for a
dropped cache: no cached price can be had); a row per choice with its
key, a button, its cost and what it does, the default marked, the
tooltip naming the writer and the context after it; and a footer with
the capitals that answer "always", a line about session_history when
the session has it, and the typed answers.  Its keymap
(`harness-ui-cowboy-keys`: b s t f c i q, capitals for "always") has
`harness-ui-pending-question-map` as its parent, so digits pick an
option as on any question; answers go through
`harness-ui-pending-answer-question` (`harness-ui-cowboy-answer`), and
text typed in the box answers it too.  Without a `:cowboy` the ordinary
question panel shows.
Lasting decisions (`harness-ui-decisions`, module `ui-decisions`): a
cache of the harness's decisions (see decisions), fetched whole with
`_harness/decision/list` on connect and after `harness/reloaded`, then
kept by `decision/changed`; `harness-ui-decision` reads one, and
`harness-ui-decision-functions` hears every change, (nil nil) after a
whole fetch.  A decision offers one button
(`harness-ui-decision-button`): [Undo] while done, [Redo] while undone,
none once ended.  They run `harness-decision-undo` and
`harness-decision-redo`, which call `_harness/decision/undo|redo`, cache
the decision returned and echo the harness's sentence; from M-x they
ask which decision, newest first.  The chat draws a note whose `:meta`
has `:decision` as `TEXT  [Undo]`, `TEXT  [Redo]` with TEXT struck
through (`harness-chat-undone-face`), or TEXT with the decision's
`:result` on the line under it once ended; a hint or tool result with
`:decided-by` gets a line `decided by: TEXT  [Undo]` the same way (in a
tool block, above the fold).  A permission note whose decision the
cache lacks follows its `:permission` `:undo`; another kind shows no
button until the cache hears of it.  Every chat redraws the blocks of a
decision that changed (`harness-chat--on-decision`), so a move made in
one session shows in all.  A decision that is a switch reads as one
(`harness-ui-decision-labels`, kind -> `(:undo LABEL :redo LABEL
:strike BOOL)`, read by `harness-ui-decision-label` and
`harness-ui-decision-strikes-p`): the kind `precompact` (compacting
before the prompt cache lapses, see cache-compact) is `[Turn off]` while
it is on and `[Turn on]` once turned off, and its note, which records a
compaction that happened, keeps its text unstruck when the switch is
off, only the button flipping; every other kind keeps `[Undo]`, `[Redo]`
and the strike-through.  A compaction node whose `:meta` has `:precompact`
says in its header "before the prompt cache lapsed" (the cowboy's says
"the prompt cache being cold").
Prompt cache warning (`harness-ui-cache`, module `ui-cache`): once the
session's `:cache :expires` has passed while it is idle or closed, a
panel above the box says so ("Prompt cache expired at
14:07, 5 minutes after its last use") and what the next message costs:
it re-sends ~N tokens (`:usage :context`) uncached, about the
cache-write (else input) price of those tokens instead of their
cache-read price, at the model's list prices, when the catalogue
prices both.  A session whose turn is still running shows none, a
session blocked on an answer included: the next request is that turn's
own, not the user's next message, and a running session's requests use
the cache again.  Nor does it show for a session this UI sent a message
that has no answer yet: `session/prompt` is answered when the turn
ends, and the UI's record of the session can be behind the harness --
an Emacs that reads its socket late still holds it idle, with the
`:cache` of the turn before -- so a panel saying the cache expired a
minute after the user's message would be false, the turn being under
way and having just used it.  `harness-ui-call-turn` (`harness-ui-call`
for a request that runs a turn: the chat's send and send-queue, a BTW's
first question) keeps each in flight (`harness-ui-prompt-in-flight-p`)
until its request settles -- answered, failed, rejected with its
connection, or its session deleted -- and runs
`harness-ui-prompt-functions` with the session's id as one is sent and
as one settles.  The panel goes as a message is sent and comes back
with the answer, or the failure, if the cache lapsed.  A turn the
harness starts by itself (the queue sent after a turn, a task's or the
supervisor's message) is not tracked, so for those a UI that lags still
relies on the session's status and live figures.  The panel reads the
newest record the UI has of the session (`harness-ui-session`: the
session list's and a fetch's too), not the chat buffer's copy of the
last update.  A session switched away from the model whose cache its
requests last used (`:cache :model`) shows the panel at once,
whatever the time ("Prompt cache cold  cached for Opus 4.6, not
DeepSeek V4"), with the same cost: the new model reads nothing of
that cache.  Switched back while the cache lasts, the panel goes; the
new model's first request stamps a cache of its own, and a switch or
compaction that starts the conversation over reports none, so no panel
(see "Session").  A cache a redaction dropped (`:cache :dropped`, see
"Session") shows the panel at once too, whatever the time, headed
"Prompt cache dropped  at 14:07, by a redaction" with the moment of the
drop, and with a tooltip saying a redaction took a secret out of the
conversation and dropped the provider's copy of it, and its prompt
cache with it.  Its cost line names the uncached price alone ("about
$0.315, at list prices"): no cached one can be had, so there is none to
compare it with.  The model switch wins when both apply: a cache held
for another model reads as that model's, dropped or not.  The first
request that stamps a cache after a redaction clears the dropped mark,
and so does a compaction, so the panel goes then as well.  While the
switch banner (`ui-handoff`) asks how to
hand over, or the cold-cache question waits (`harness-ui-cache--asked-p`),
the panel stays away: the banner's options, or the question's, say what
the cache means for each.  The panel needs no input and no polling: each
chat buffer holds one timer, for the moment its cache lapses, which
redraws the box and whatever panel is above it (`harness-compose-redraw`);
a session update (a new request stamps a new `:cache-at`) reschedules
it, and the panel goes as soon as the session runs or a message is
sent.  Its text names clock times only, never "idle for", so nothing in
it goes stale between redraws.  A session without context or cache use
never shows it.  Its last line offers to compact the conversation
first, so the next
message sends only what stands in for it: a button per kind
(`harness-ui-compact-kinds`), the brief summary first -- the cheap way
out of a long conversation gone cold -- then the summary, the
transcript file and a fresh start, each with its key on that line (b,
s, t, f, through a
keymap composed under the buttons' own, `harness-ui-with-keymap`) and
what it costs (`compaction/estimate`, asked once per state the panel
shows, `harness-ui-cache--estimate`, and drawn when it comes; the
buttons only name the kinds until then, a transcript being free).
Pressing one runs `compaction/compact` (`harness-ui-compact-run`); the
line says so while it runs (`harness-ui-compact-doing`), and the panel
goes once the compaction resets the cache.  A session the cowboy
module compacts before a message shows as running with the activity
`compacting` meanwhile, so the panel offers nothing then either.  A
session blocked on an answer is in the middle of a turn, so it shows
no panel at all.
Cache warming (`harness-ui-cache-warm`, module `ui-cache-warm`): while a
session's cache is being kept alive (`cache/warm`, see cache-warm), its
chat's header line shows a flame (`harness-icon-flame`, `icons/flame.svg`,
the fire emoji as the terminal fallback) and a coarse countdown to the end
of the warming period -- `12m`, `1h20m`, `<1m` -- in `harness-chat-warm-face`,
dim in the last minute, through `harness-chat-header-end-functions` at
priority 15 (the spend goes before it in a narrow window, the rest after).
The state comes as `cache/warm-changed` events and `_harness/cache/warm-list`
on connect and after a reload (`harness-ui-cache-warm-state`,
`harness-ui-cache-warm-functions`); one 15-second timer redraws the
countdowns while any shows and stops when none does, so nothing polls the
harness.  It shows while the turn waits on a tool call too (`:tool`), and
dim, "off", for a period the user set while the harness is blocked
(`:blocked`: it would cost about what sending the conversation again does,
or a refresh did not read the cache), the reason in its tooltip.  The
tooltip says why the cache is warm, until when, the next refresh, how many
were made and what a refresh costs against sending it all again.  Every
chat buffer reports the user active through a `post-command-hook` -- any
command run while the buffer is in the selected window, typing in the box
included -- as `_harness/cache/active`, at most every 20 seconds; a
harness without the module answers method-not-found and the UI stops
reporting until it connects again, saying nothing.  `harness-cache-keep-warm`
(`K` under the harness prefix and in the menu, `/warm DURATION` in the
box, a click on the flame) asks for a period of the user's own with
completion over 15m, 30m, 1h, 2h and off (`harness-ui-cache-warm-parse-duration`
reads `30m`, `1h30m`, `1,5h`, `90` as minutes, `off`), at most 24 hours, calls
`cache/keep-warm`, and says in the echo area until when, about how many
refreshes (at most the harness's `:max-refreshes`) and what they cost
against sending everything again, or why nothing is kept warm.
Tools go by their labels everywhere: a tool block's header shows the
label in `harness-tool-title-face` and what the call is about after it
in `harness-tool-subject-face` (the faces stand in for the colon of the
title), a summary block counts the calls by label ("5 tool calls: Read
file ×3, Search files, Find files", then " · thinking ×2" for the
thinking folded in with them; a run of one names its call, label and
subject, in plain text), and so do the permission panel,
the activity line and the spinner's tooltip.  A title recorded before tools had
labels starts with the tool's name ("read_file x.el"), which the label
replaces, so old transcripts read the same.  Under a folded call's
header one dim line sums up the input its title leaves out
(`harness-ui-tool-input-summary`): a list reads as its labels,
comma-separated, and a list of other objects, such as the items of a
todo list, as how many there are, never as a Lisp form; a todo_write,
whose title already counts its items, has no such line.
A call naming a session in `:meta` `:child-id` (a `spawn_agent` call
once its result names the sub-agent, or the merge queue's call for its
conflict resolver from the start) gets a `session:` line, also above
the fold, whose button opens that session; the call's whole block opens
it too, from its title, input or output.  A call naming sessions in its
input (`session_id`, `session_ids`: what `session_read`,
`session_send`, `session_wait`, `set_priority` and the other session
tools are given) gets the same line, `sessions:` when it names several.
Its references are resolved against the session cache the way the
session tools resolve them (`harness-ui-resolve-session`: an id, then a
unique id prefix, then a unique name, compared without regard to case),
so one that names no session, or several, shows no link, and the chat's
own session is left out.  Full session ids printed in a call's input
and output -- a `session_list` listing, a `session_wait` report -- are
session links too (`harness-ui-link-session-ids`), both in the chat and
in the report popout: only a whole id the cache knows counts, never a
short one, which is as likely a git hash, and a call's block-wide keys
stay under such a link, so the id opens its own session and the rest of
the block the call's.  Every clickable session name
in the UI is drawn by `harness-ui-session-link` (this line, the sender
of a message from another session, the panels of the merge queue and
of the running sub-agents...): face `harness-ui-session-link-face`, a
click or RET opening the session through `harness-ui-visit-session`,
which switches to the session's project first, as a row of the session
list does.  `harness-ui-session-action` is that same action for text
wider than a name, the call's whole block for one.  A call the harness
recorded (`harness-outside-node-p`) opens a turn of its own under its
sender's line, as that sender's message does, rather than joining the
agent's turn or a run of calls, and shows as running until its result
comes, whatever its session is doing.
Auto-scroll follows unless the user scrolled up.  While a window on the
chat is away from the end, scrolled up by any command or moved there
with the jump keys, the header line shows "↓ newer messages", which
jumps back down.  The header reads a flag, `harness-chat--notice`, that
the post-command hook and `window-scroll-functions` keep current; it
never measures the window itself.  `pos-visible-in-window-p` measures
a window's header line by formatting it, so a header that called it
would be evaluated again inside itself, without end, until
`max-lisp-eval-depth`: the header drawn empty, the mode line losing its
status, and every redisplay taking seconds.
While the session
runs, an activity line under the last block says what the turn does
and for how long: waiting for the model, thinking, writing, preparing a
tool call (with the size of its input so far), running one (with the
last line it reported), checking its permission, or compacting, behind
a spinner.  It is an overlay string redrawn by the spinner's timer, so
it ticks without editing the buffer; a blocked session shows its panel
instead.  The overlay sits, empty, where the line goes
(`harness-chat--activity-position`): the end of the transcript, or,
where `harness-chat-top-functions` drew something (the pet's figure,
which then stands on the line), the end of that text, which the property
`harness-chat-top` marks.  A render of the tail takes the overlay off
its place and `harness-chat--refresh-activity` puts it back.  The mode
line's spinner gives the phase only in its tooltip:
this line is where it shows.  It has a background of
its own (`harness-chat-activity-face`) and a blank line under it, which
set it apart from the compose box: an overlay string is drawn over the
face of the text it precedes, the box's prompt, so both lines are drawn
over `default` extended to the window's edge.  A buffer opened
mid-turn asks `agent/activity`; a harness that reports none gets
"Working" with the turn's duration.  A block whose renderer
signals is shown unformatted with a note, so one bad node never costs the
buffer the rest of its transcript or its compose box.  Opening a session
from any view never resumes it: an inactive session shows its transcript,
a notice and the compose box, and the first message sent from it resumes
it (through `agent/prompt`).  The header and mode lines hold only what
the buffer does not show, and what matters.  The header line shows the
session's name, model, permission mode, "non-interactive" (in
`harness-non-interactive-face`) while it is, thinking level, context,
cost and [menu]; clicking a setting changes it, and "non-interactive"
makes the session interactive again.  A narrow window drops the cost
first, then the thinking level, the context and the model.  The mode
line has the status: its icon and word, the spinner while a turn runs
(its tooltip says what the turn does), and the turn's duration while
the turn runs, not while the session is blocked waiting on the user.
The todo list is left to its panel above the compose
box, what the turn does to the activity line, and the output tokens and
rate to the session list and the tooltip of a task card's title.  The output
rate ("48 tok/s", `harness-ui-format-rate`) is the session's rate as the
usage module measured it. It is dimmed when the session is not running,
because it is then the last rate measured. The session has no rate
until it has been measured.
The UI keeps the rates in a cache (`harness-ui-session-rate`). It is
filled with `_harness/usage/rates` on connect and kept current by
`usage/rate-updated`. Every change runs `harness-ui-rate-functions`,
which redraws the session list; a task board does not redraw for it, as
no card shows a rate (a card's tooltip reads it when it is asked for).
The session list's Avg tok/s column and the tooltip of a task card's
title show the average over the whole session instead ("48 tok/s avg",
`harness-ui-format-average-rate`; the column leaves out the unit):
`harness-ui-session-average-rate` divides the `:stream-output` of the
session's usage totals by their `:stream-seconds`, and gives nothing
without them or with under a second of streaming.  It is not dimmed when
the session is idle, being no last rate, and its tooltip says what it
is, how much output over how much streaming, and names the current rate
beside it (`harness-ui-average-rate-help`) when one was measured.
The context ("12.3k/200k", `harness-ui-format-context`) and the output
tokens ("3.4k out", `harness-ui-format-output`, none until the session
wrote some) read `harness-ui-session-tokens`: the session's totals, or
while its turn runs the usage module's live count, so both grow as the
model streams; "~" marks figures partly estimated from what streamed
since the provider last reported usage.  The UI keeps the live counts
in a cache too (`harness-ui-session-live`), filled with
`_harness/usage/live-all` on connect and kept current by
`usage/live-updated`.  The event that ends a turn's count can come
before the session's new totals (sessions are pushed after a short
debounce), so the last figures stand until the cache shows the session
no longer running and never drop in between.  Every change runs
`harness-ui-live-functions`: the chat headers redraw (a few times a
second at most, as the events come) and the session list at most every
half second, and only when a figure they show reads otherwise; the task
boards do not, as no card shows a figure (a card's tooltip, made when
it is asked for, reads the count as it stands).
The context figure is a button (`harness-ui-context-limit-map`): in the
chat header it is a segment as the settings beside it are, and in the
session list a click acts on the session the figure shows.  Mouse-1 on it, or `C-c h e` (`harness-set-context-limit`),
offers that session's context window limit: the current one, a few
round sizes under the model's own window (read from its catalogue
entry, never assumed), and no limit, which uses the whole of it; a
number typed instead sets that many tokens, clamped to the model's
window.  The offer names what holds the window: a sub-agent's limit
(`harness-subagent-context-limit'), a task's
(`harness-tasks-context-limit'), or one set for the session itself.
The change is a `session/update' of `:context-window-limit' -- a window
set for the session outright is cleared with it, since it would win
over the limit (see `harness-ui--apply-context-limit') -- so the
conversation is neither restarted nor compacted: the header line and
the other views show the new window at once, and the new limit takes
effect at the session's next request.
Other UI
modules hook into a chat buffer without owning it:
`harness-chat-send-functions` sees each message sent
or queued from its box (the text as typed, and the attachments),
`harness-chat-header-functions` (buffer-local) puts segments in front of
its header line, leaving the session's own segments as they are, each a
string or `(TEXT PRIORITY MIN)` as `harness-ui-fit-header` takes it,
`harness-chat-header-end-functions` adds segments after the session's
own, before [menu], each a string or `(TEXT PRIORITY MIN)` as
`harness-ui-fit-header` takes it (the companion pet's face, priority 2,
goes first in a narrow window), and the
buffer-local `harness-chat-placeholder` replaces the empty box's usual
hint.

Supervisor mode (`harness-ui-supervisor`, module `ui-supervisor`, which
requires `ui` and `ui-chat`): a session the supervisor module governs
says so in its `:ext` `:supervisor`, `t` while it supervises and
`:false` once the user turned that off, and the chat's header line then
starts with the state, before the session's own segments, through
`harness-chat-header-functions`: " supervisor " in
`harness-supervisor-face`, or " hands-on " in `harness-dim-face`, padded
from the window's edge and separated from the session's name as the
header's other segments are.  The segment is fitted at priority 3, below
every segment of the session's own, so a window too narrow for the whole
line drops the badge before it loses the model, the permission mode or
the rest.  A session with no `:supervisor`
(a sub-agent, a side conversation) shows nothing.  A click on the
segment, and `V` in the harness keys (`C-c h V`,
`harness-toggle-supervisor`), toggle the mode: they ask for the opposite
with `_harness/supervisor/set {sessionId, on}` and say what changed
("Supervisor mode on", "Supervisor mode off (hands-on)"), and the header
follows the session as the harness sends it.  The command takes the
buffer's setting target like the other session settings: a session it
refuses when the harness has not sent it or the plugin does not govern
it, and the task board's non-session target -- the setting of the next
task, offered only while the harness has the supervisor module -- it
toggles through `harness-ui--setting-set' as the board's other setting
buttons do, as it does the session list's marked sessions
(`_harness/supervisor/set-all' with their ids, and their tasks' setting
through `task/set-all'); a harness without the supervisor module
does not know the method, which is said plainly ("Supervisor mode is not
available") rather than as a failure.

`harness-set-supervisor-all` is the mode's "for all sessions" command
(the menu's V, beside I), and is autoloaded like the others: it asks on
or off, offering on first, and calls `_harness/supervisor/set-all
{on, filter}` with `harness-ui--everything-filter`, so every governed
session changes, a completed task's left alone, and a sub-agent or side
conversation untouched.  Unless a prefix argument says otherwise it
also sets `harness-supervisor` and `harness-supervisor-tasks` globally
through `config/set`, so new top-level and task sessions follow, then
reports how many sessions changed with `harness-ui--new-work-text` and
`harness-ui--report-all` (what a project's `.dir-locals.el` still says
otherwise).  Its failures go to `harness-ui-supervisor--failed`, the
same plain message for a harness without the module.

Session priority (`harness-ui-priority`, module `ui-priority`, which
requires `ui` and `ui-chat`): a session whose `:ext' `:priority' is not
the default, medium, shows it as an arrow, one arrow made in one place
-- `harness-ui-priority-arrow', the arrow up of
`harness-icon-priority-high' in `harness-priority-high-face', or the
arrow down of `harness-icon-priority-low' in
`harness-priority-low-face' (dim) -- which the chat's header line puts
beside the session's name through `harness-chat-header-functions', the
session list's Priority column shows in its row, and a board's cards
carry before their title.  A session at the
default, one whose priority the harness has not sent, and one whose
priority this UI does not know, show nothing.  The arrow is a button
(`harness-ui-priority-click', through `harness-ui-mouse-keymap'): it
carries its session id in the `harness-priority-session' text property,
so a click acts on the session of the arrow clicked rather than the one
in front of you, and offers the possible levels as a menu at the click
-- highest first, the level in force greyed out -- setting the one
chosen (`harness-ui-priority--ask', `--menu'); a click that chooses
nothing changes nothing.  `y` in the
harness keys (`C-c h y', `harness-set-priority') does the same without
a click, reading the level in the minibuffer with the session's own as
the default (`harness-ui-priority--choose', the one place the levels'
order and prompt live, which the session list's `p' reads through too
for its marked sessions); either way the request is
`_harness/priority/set {sessionId, priority}', and the answer says what
it is now ("Priority: high").  `+` and `-` in the harness keys
(`C-c h +', `C-c h -', `harness-priority-raise' / `-lower') move the
session in front of you one level up or down, saying so, and saying it
is high or low already at the top and the bottom; with a prefix
argument they ask for the level instead, as the setter does, and `Y'
(`harness-set-priority-all') gives every current session and task
session one at once (`_harness/priority/set-all {priority, filter}',
the filter `(harness-ui--everything-filter)'), reporting how many
changed.  The four are the menu's own "Priority" column, standing
beside "Session settings" so the settings column keeps the room a
short frame has: Raise priority (`+`), Lower priority (`-`), Set
priority… (`y`) and Priority for all sessions… (`Y`).
Every command takes the buffer's setting target like the
other session settings, and every one of them works on a session: a
priority is the session's, so the setter refuses the board's new-task
settings (a task that has not started is set on its card, `+` or `-`)
and a session the harness has not sent; a harness without the priority
module does not know the method, which is said plainly ("Priority is
not available") rather than as a failure.  No command of this
module refreshes anything itself: `session/set-ext'
announces every change of a session (a pushed `_harness/session', and
`session/ext-changed'), the pushed session updates the UI's cache and
redraws the header, and the module follows `session/ext-changed' for
the priority's key by reloading that cache
\(`harness-ui-refresh-sessions'), which is how a priority set from
anywhere -- the board's task, another client, `set_priority' -- shows
up in the header and the session list on its own.  `C-c h p' stays the
permission mode: the priority commands took `+', `-', `y' and `Y'
rather than it.

Compose box (`harness-ui-compose`): the editable box shared by chat
buffers and the task board.  A host calls `harness-compose-setup`
(`:project`, `:placeholder`, `:redraw` functions; `:bottom` keeps the box at
the bottom of the window) from its mode and
`harness-compose-insert` where it draws the box; it gets multi-line
editing whose lines wrap under the text and never scroll sideways (the
whole host buffer wraps, so a host fits the lines it wants kept on one;
with `:bottom` the growing box keeps its last line on the window's last
line, in a window shorter than the buffer too, a board under a BTW say,
by scrolling that never moves point out of the box), a prompt that is a
field of its own (`C-a` stops after it, so
`C-a C-k` clears the line), the placeholder, @file, @task: and /skill
completion, attachments of files, images and tasks (`C-c C-a`, pasting
`C-y`, drag and drop) with a chip in the text for each, skill expansion
(`harness-compose-with-expanded-text`) and ACP attachment blocks, the
keys of the panels above it pressed from the box (`C-c .`), and `M-<`
and `M->` that stay in the box.  `harness-compose-insert` takes `:face`,
the box's background (`harness-compose-face` by default) and `:accent`,
the face of the prompt and of the bar down the box's left edge, through which a
host whose box does something else than compose -- the task board's,
which sends to a session -- marks it; `harness-compose-bar` draws that
same bar on the host's own lines around the box.  Without either
argument the box is the plain one.
A host draws the attachments above the box with
`harness-compose-insert-attachments`, one a line: the paperclip leads
the first, the names under it line up with its name, and a prefix the
host passes starts every line (the board's message box passes its bar).
Each line is fitted to the narrowest window showing the buffer -- the
daemon's initial frame, which never shows, aside -- in pixels of the
frame drawing it (`string-pixel-width`, so icons, thumbnails and text
scaling count): a name too long is shortened in the middle
(`harness-compose--shorten`), keeping its start and, room permitting,
a path's whole file name, while the tooltip tells the whole path; a
thumbnail takes a third of the room at most, and a download keeps room
for its progress at its widest, so its line never grows as it ticks.
When a window showing the box changes size, the box has its host draw
the lines again (a buffer-local `window-size-change-functions`,
debounced, and only once the room really changed).
An attachment chip leads with a thumbnail (`harness-compose-thumbnail-lines`)
when it is an image, or a video whose thumbnail the media module makes
with ffmpeg in the background (a chip asks for it through
`harness-ui-media-video-thumbnail' and is drawn again when it lands).  A
link dropped from a browser or a page (`dnd-protocol-alist` for
http/https/ftp, plus the X types through `x-dnd-types-alist`: a raw
image, a browser's file promise, `text/html`, text, and X direct save)
downloads with `harness-http-download` behind a chip whose spinner,
progress bar and size an overlay redraws, so the buffer's text is not
touched while it ticks; the file attaches under the name the server or
the link gave, or the link goes in as text when it turns out to be a
web page.  Sending waits for a download in flight.  The X handlers take
what the drop says the dragged media is (a browser's `text/html` or
`application/x-moz-file-promise-url` names the image inside a link),
and dropped text goes into the box rather than into the read-only
transcript around it.  A link off a selection arrives propertized
(`foreign-selection`), which is why the code that hands one to curl
strips text properties first.
Media on the clipboard is read without touching `kill-ring`: `C-y` in a
compose box attaches the image, or the files a file manager copied, and
pushes captures on the media ring (`harness-ui-media-ring`), a ring of
its own under `harness-state-directory/clips/` deduplicated by the
SHA-1 of the bytes, which `M-y` goes back through and
`C-u M-x harness-compose-attach-clipboard` picks from; `yank-media`
attaches them too (`harness-compose-yank-media`).  The box binds no
`C-c C-v`: in a chat that is the review banner's [Verify], so the two
never fight, and other MIME types are chosen from with
`M-x harness-compose-attach-clipboard`.
Inline chips and tokens: an attachment gets a token in the text, where
point is in the box, else at its end (a download's always at the end, as
it lands later), kept apart from the words around it
(`harness-compose--label`).  An image attached however
(`harness-compose--attach`) gets a `:label`, "image 1", and its token is
`[image 1]`.  A file gets its @ reference as `:ref` -- the name `@`
completed when that names the file, else its path in the project, else
under `~` or absolute (`harness-compose--file-ref`) -- and its token is
`@` and that; a path with a space would end the reference, so such a
file has no token and takes no part.  A task has `:ref` "task:ID", so
its token is `@task:ID`.  The token is plain text, so it survives
redraws, drafts, queueing and editing a queued item like the rest of the
message, and a reference typed or completed in the box is the token of
its attachment all the same.  One function draws every kind
(`harness-compose--inline-chip`), so the three look and act alike: an
overlay per token (`harness-compose--show-tokens`) whose `before-string`
leads with what it is -- an image's thumbnail a line high (an image
inside a `display` string would not draw), the icon of a file or a task
(`harness-icon-file`, `harness-icon-task`) -- and whose `display` is the
token as a link in `harness-compose-token-face`
(`harness-compose--chip-text`): `[image 1]`, a file's `@` and its name
without directories, shortened in the middle to 32 characters, a task's
`@task:ID` and its title cut at 32.  The command loop's point adjustment
makes point step over it whole.  `harness-compose--chip-map` gives all of
them the same clicks: mouse-1 and mouse-2 open the attachment
(`harness-compose-open-attachment`: a video or a sound in the media
module's player, any other file in a buffer, a task its session's chat
or else its card on the board, `harness-ui-tasks-show-task`), and
mouse-3 pops up a menu of `harness-compose--chip-actions` -- Open,
Remove from the message, Copy the path (the id, for a task); the tooltip
says what it is, and that deleting the token removes the attachment.
After every command `harness-compose--sync-tokens` makes text and
attachments agree: what is left of a token cut short goes too, an
attachment whose tokens are all gone is detached and kept in
`harness-compose--detached` (with its place in the list), and one kept
there whose token is back (undo, yank, typing) comes back in its place;
× on the attachment's line and the menu's Remove delete its tokens with
it (`harness-compose-remove-attachment`, which takes a file's path, a
task's `task:ID` or the attachment).  New text (`harness-compose-set`,
`harness-compose-insert` with TEXT) forgets the kept ones.  An image's
number never changes once given, since a sentence names it: a new image
takes one more than the highest attached, so deleting the last frees its
number and one in the middle leaves a gap, and each message starts at 1.
Unlabelled images (a draft from before) take no part.  The attachment
lines stay, each image's led by its token, since they also show files
with no token, downloads in flight, size, the larger thumbnail and ×; a
task's reads "ID · Title (state)".  `harness-compose-attachment-block`
puts the label in the ACP image block's `_harness.label`;
`harness-acp--block-from-acp` makes it the block's `:label`, which
`harness-attachments-to-blocks` keeps for queued messages and
tasks.  `harness-agent--prepare-content` puts a text block of the token
right before each labelled image of a user message for every provider
(Copilot also names the image's blob after it), and
`harness-blocks-text` leaves out the image placeholder of a
labelled image the text names already, and a file's `@name` when the
text has an @ reference to it (`harness-names-file-p`), so a
file the box referenced is not named twice in the transcript.  A user
message that answers the model inline -- quotes a part of its message
and answers under the quote (`harness-agent--inline-reply-p`) -- gets a
note of the harness's too, saying to answer the same way, quoting each
part answered (`harness-agent--inline-reply-note`).  Only the model
reads it: it is added to the request the harness builds, never to the
transcript, which keeps the message as the user wrote it.  A message
that only quotes, a region prompt say, is not answered inline and gets
none.  These three live in `harness-util` (the agent's old names are
aliases of them): the chat reads a queued message with them as the agent
will record it (`harness-queued-message-node`).  Queued
items sent as one message number their images on across it
(`harness-agent--queue-blocks`, tokens rewritten with them).  The chat
styles the references of what a user message attached in its text -- the
tokens of labelled images, the @ references of files attached, @task:
ones -- in the face of the box's chips, with a tooltip saying what they
are, and puts each image's token over it
(`harness-chat--mark-references`, `harness-chat--blocks-string`).
Tasks: `harness-compose-attach-task` attaches a task of the box's
project, given its id or its record, or read with completion by title
(`harness-compose-read-task`).  `C-c C-a` takes `task:ID`
(`harness-compose-add-attachment`), `@task:` completes the project's
task ids in the box, each with its title and column, the one chosen
becoming the attachment, and `@` on a card of the task board does it for
that card's task (`harness-ui-tasks-attach`).  The tasks are listed from
`_harness/task/list` along with the files (`harness-compose-fetch-tasks`),
never waited for: a task not listed yet is attached when the list
comes, its reference at the end of the box.  The attachment has no file:
`:task` is the id, `:name` the title, `:session`, `:state` the column,
`:mime` `text/x-harness-task`, and `:text` what the model reads of it
(`harness-compose--task-text`) -- id and title, column and state,
priority, session and branch, the prompt cut at 3000 characters and
where to read more with the task tools.  An attachment that has a `:text`
and no `:path` goes as a text block of that text:
`harness-compose-attachment-block` makes the ACP prompt block of it, and
`harness-attachments-to-blocks` the block of a queued message or a
task's prompt, so the task goes wherever attachments do and nothing
needs a file.  The block is marked as an attachment's text -- the ACP
block's `_harness.attached`, which `harness-acp--block-from-acp` keeps
as the block's `:attached`, as it does an image's label -- so that
`harness-blocks-text` puts it after the user's words, a paragraph
of its own, instead of running it on from them; the model gets it as a
block of its own without the mark (`harness-agent--prepare-block`).  `harness-compose-without-references` takes a task whose
reference the text holds with the files it names: an answer to a
question carries no attachment, and what the text names goes as the
reference.
Undo in the box: hosts draw with undo off, so what they draw above the
box moves its text but not the positions its undo entries record, and
undoing right after attaching (its line drawn above the box) would
change the read-only text.  `harness-compose--line-up-undo`, on
`pre-command-hook` and `before-change-functions`, moves every position
in `buffer-undo-list` (in place, so `pending-undo-list` follows) by as
much as the box's start moved since the last time.
Completion reads the project's files and the skills when it is asked,
so a token typed before they arrived is offered them once they have.
Popups that show as you type (corfu's `corfu-auto`, company) give up
when the buffer changed since the last key, and a host changes all the
time (a chat streams, a board follows its tasks): once the token stops
changing, the box asks them again (`harness-compose--popup`).  @ and
`C-c C-a` find files through one table (`harness-compose--file-table`):
part of a name matches the project's files, never listing while you
wait, and a path -- starting with `/`, `~`, `./` or `../`, the relative
ones against the box's project root -- completes over the file system
directory by directory in the `file` category, with file name handlers
off so that a remote name never opens a connection.  A completed path
attaches only a regular file; a directory stays in the box for its
files to complete.  `C-c C-a` ignores a leading @, and a directory
chosen there reads again from inside it; `C-u C-c C-a`, or a directory
that is no project, browses with `read-file-name`.  An @
reference typed out in full, or pasted, names its file all the same:
`harness-compose-take` attaches the regular files the references in the
text name (`@skill:` ones and missing files aside, trailing punctuation
tolerated) and leaves the references in the text.  An answer to a
question, in a chat, on the board or in a popout, carries the box's own
attachments, a screenshot its text names by its token among them,
while a file the text names stays its reference
(`harness-compose-without-references`): `harness-ui-pending-answer-question`
sends them as `harness-compose-attachment-block` makes a message's, an
image with its bytes, and the harness hands them to the model with the
answer (see `question/answer`).

Quoting to reply is the `compose-quote` library's (lisp/vendor/compose-quote;
see Vendored libraries), which knows nothing of the harness: the box is
only the composition it quotes into.  `C-c >` in the box's keymap is
`compose-quote-reply`; it puts what a reply answers in the box as a
Markdown quote, its lines after "> ", with point under it, a blank line
apart (`compose-quote-insert`, `compose-quote-string`).
`harness-compose-setup` makes its buffer a quoting one
(`harness-compose--setup-quoting`, which turns `compose-quote-mode` on)
by setting what the library asks of a host:

- `compose-quote-area-function` is `harness-compose--quote-area`, the
  box as the composition: (START END FRONT), the box's text and FRONT,
  where the box starts with its prompt (`harness-compose--front`); nil
  without a box.  Only the part of a region above FRONT counts, quoted
  at the box's end, and a region within the box turns into a quote where
  it is.
- `compose-quote-source-function` is `harness-ui-markdown-source`, which
  reads the text of a region over the host's transcript back into
  Markdown as it shows.  It undoes the renderer from the faces and
  properties it left: fenced code gets its fences back, its language
  from the label line above the block, code spans their backticks,
  links their `[label](url)`, bullets their `-` and the quote bar its
  `>`, while invisible text -- a folded block's body -- is left out.
- Without a region the message at point is quoted whole, as written, at
  point in the box or else at its end.  Which message that is the host
  says: text it marks with a `compose-quote` property, a string, is
  quoted as that Markdown (a report's summary carries it,
  `harness-ui-report--insert-message`, into the chat's review banner
  too), and elsewhere the buffer-local `compose-quote-function` returns
  it -- the chat's `harness-chat--quote-at-point` the response, plan or
  thinking point is on, else the nearest response or plan above point,
  so the last one from the box; a report popout's
  `harness-ui-report--quote` its summary.
- A chat's message comes with the thread it answers
  (`harness-chat--quote-markdown`): an answer that quotes nothing itself
  is quoted with the message it answers nested under it, one `>` level
  deeper, so the replies of a thread quote each other and it reads back
  in order.  A message that holds a quote of its own is quoted as it
  stands: its writer answered inline, so it carries the thread already,
  and nesting its parent too would say the same thing twice
  (`harness-chat--quoted-markdown-p`, `harness-chat--answering-block`,
  the newest user message older than it among the blocks the transcript
  holds).
- `compose-quote-insert-hook` has `harness-compose--quoted` on it in the
  box's buffer: the box may be out of sight, so it counts a jump
  (`harness-compose--jumps`), which makes its windows follow it again,
  and it updates the placeholder.

Answering inline: `compose-quote-mode` also keeps `compose-quote-inline-mode`
on while point is in a quote in the box, and off elsewhere (on
`post-command-hook`).  A quote is a run of lines of the box that start
with `>`, so one typed or pasted in counts as much as one `C-c >` put
there, and a `>` line of the transcript never does.  In a quote `M-RET`
(`compose-quote-split`) splits it where point is -- the part above, an
empty line for the answer to it, the part below -- and `C-c [`
(`compose-quote-elide`) replaces the region, or the rest of the
paragraph from point (with a prefix argument, the rest of the quote),
with `[...]` (`compose-quote-elision`), so a bit of front matter stays
for context.  Both are edits of the box's text, one undo each, and what
is sent is the text as it stands.  The echo area names the keys as point
enters a quote (`compose-quote-inline-hint`).  The harness menu lists
the keys for the chat and the popout.  The inline mode's map binds those
two keys and nothing else: it outranks the host's map while point is in
a quote, so any other key it took -- `C-c .`, say, which a host may bind
for the box -- would stop working there
(`harness-ui-compose-quote-leaves-the-box-keys` checks every key of the
box).  The thread of a specific thing goes on from both sides: the chat
quotes a message with the message it answers nested under it (see
above), and a message of the user's that answers the model inline
reaches it with a note saying to answer the same way
(`harness-agent--inline-reply-note`), so its answers quote the parts
they answer in turn.

The harness's own quoting names are obsolete aliases of the library's:
`harness-compose-quote-reply`, `harness-compose-quote-string` and
`harness-compose-quote-function`.  The alias of the variable cannot be
made in a harness reloaded from before the library, where chats have the
variable buffer-local, so loading the compose box sets such a buffer up
for quoting and moves its `harness-compose-quote-function` to
`compose-quote-function`.  The function `harness-compose-quote` and the
text property of that name are gone: nothing reads the property.

A panel's key, from the box: what sits above the box and binds keys of
its own -- a question's digits, a permission's y, s, a, n and N, the
cache panel's and the model-switch banner's choices, the task board's F
and the other keys of its cards, a popout's q and g -- acts while point
is on it, and in the box the same keys type (`harness-compose--pre-command`
sends typing from outside the box into it, unless the key is a command
where it is typed).  `C-c .` (`harness-compose-panel-key`, in
`harness-compose-map`: `.` is free after `C-c` in every host, and the
harness menu already writes a view's plain keys behind a dot, ". F") is
the one way to press one from there.  It reads a key sequence and finds
the panel above the box that binds it, runs the command with point on
that panel, as its keymap would, and puts point back in the box at the
same offset in it, whatever the command redrew (answering a question
draws the panels and the box again).  The host says which text is a
panel with a `harness-compose-panel` property, valued with something
that names it: a request's id for the pending panels
(`harness-ui-pending--decorate`), `cache`, `switch`, `board`, `popout`
(`harness-ui-popout--mark-panels`, which leaves the names of the panels
the content drew itself alone); neighbouring text with an `equal` value
is one panel, however many pieces the host drew it in.  A panel's keys
are those of its own `keymap` or `local-map` property, never what the
buffer's modes bind.  The panel nearest above the box that binds the key
wins; a numeric argument takes the Nth up.  A key bound to a command
that acts on what is at point, and says so with a
`harness-compose-acts-p` property (the board's keys for a task, an
option a question has not), is no key to press from the box when that
finds nothing at the panel's start: that is said, and nothing runs, as
is no panel having the key.  The panels say how to press theirs:
`harness-compose-panel-hint` is the dim "from the box: C-c . 1" line a
permission's panel (with its first answer's key), a question's (the
digit 1), the cache panel, the cold-cache question and the model-switch
banner each carry, `harness-compose-panel-keys` is where the box binds
the command so that a rebinding is followed, the tooltips of the chat's,
the popout's and the board's boxes name it (a board's empty box in its
hint too), and the harness menu lists it among the commands of each.

The top and the bottom of the box: `M-<` and `M->` in `harness-compose-map`
run `harness-compose-beginning-of-buffer` and
`harness-compose-end-of-buffer`, as do the remappings of
`beginning-of-buffer` and `end-of-buffer`, so `C-<home>` and the rest
follow (a minor mode's remap of the command outranks a major mode's,
but not a binding of the key to a command of our own, as with `C-y`).
In the box, short of its edge, they leave the mark where point was and
go to the box's start or end, as the buffer commands do for the buffer;
at the edge already, from outside the box, or with a prefix argument
they are the buffer's own, so a second press goes on to the top or the
bottom of the buffer: the transcript above the box is read, not edited,
and what to move over in the box is the box.

Prompting with the region: `harness-prompt-region` (`C-c h >`, bound in
`harness-ui-map` when the chat module is ready, and `>` in the harness
menu; autoloaded) starts a message with the active region of any buffer,
not only a harness one.  In a buffer with a live compose box -- a chat,
the board, a popout -- it is `harness-compose-quote-reply` of the
region.  Anywhere else the text goes into the box of the newest session
of the buffer's project (`harness-chat--project-sessions`; with a prefix
argument one chosen among them or a new one,
`harness-chat--read-prompt-session`; a project with no session gets one
through `harness-new-session`, whose CALLBACK is called with the new
session's buffer once it shows) as the start of a message
(`harness-chat--region-prompt`): a line saying where it comes from --
the file's path relative to the project root, else abbreviated, with its
lines, or the buffer's name --, then the text, in a fenced code block in
the buffer's language (`harness-chat--code-language`; the fence longer
than any run of backticks in the text) when the buffer is a `prog-mode`
or `conf-mode` one, otherwise as a Markdown quote
(`harness-compose-quote-string`).  Blank lines around the text are left
out, and the lines named are those of what is left.  The chat is shown
and selected, the text appended to the box under a draft, a blank line
apart, with another blank line after it and point there, ready for the
request (`harness-chat--append-to-box`); a box not drawn yet keeps the
text for when it is.

Dragging images out (`harness-ui-drag`): the images the UI shows -- the
transcript's (`harness-chat--image-string`, `harness-ui-image-string`),
a compose chip's thumbnail and name, a report's and the image popout's
-- drag into another application as a file.  `harness-ui-drag-source`
(a string), `harness-ui-drag-region` (buffer text) and
`harness-ui-drag-props` (a plist of text properties about to be put on
text, the image strings' click properties, so that an image drawn in
pieces, line-high strips say, drags from each) set the
`harness-ui-drag` property, the file or t for the image displayed
there, lay `harness-ui-drag-map` (down-mouse-1) over the keymap the
text already has, and add a word to its `help-echo`.
`harness-ui-drag-start` follows the mouse with `track-mouse` while the
button is down: a release before it moved `harness-ui-drag-threshold`
pixels goes back to `unread-command-events` as a mouse-1 click, so
links, buttons and `follow-link` work as before; further, it is
`dnd-begin-file-drag`, whose drop on the source frame itself is
ignored, so letting go over Emacs cancels.  An image held only as
`:data` is written to the session's own temporary directory
(`session/tmp-dir`) as `image-SHA.EXT`, SHA the start of its bytes'
SHA-1, so a second drag writes nothing; the directory is asked for when
such an image is drawn and again on the press, and never waited for:
until it is known, and for a buffer of no session, the file goes to a
private directory of this Emacs (mode 700), deleted when Emacs exits.
Nothing is made draggable where `x-begin-drag` is missing (only X,
macOS and Haiku start drags), nor is a remote file, which the drag
would copy here while the UI waits; on a text terminal's frame a press
is a plain press.

Views share positions with sessions: the task board, session list,
usage dashboard, Insights report, worktree list, conversation tree and log open through
`harness-ui-display-view`, replacing the session in their position (and
returning to the position they had last); a session opened from a view
(`harness-ui-session-opener`) replaces the view.  Menus, help and the
BTW overlay keep their own windows.  `harness-ui-display-buffer` and
`harness-ui-display-view` take a frame (the selected one by default):
the buffer shown in the position of that frame is the one replaced, one
shown in the same position in another frame is left alone, and the
frame's own fullscreen layout is the one consulted.  There is no frame
chooser of the harness's own: a view or session shows in the selected
frame, and Emacs's window prefixes send it elsewhere, as for any
buffer.  `C-x 4 4`, `C-x 5 5`, `C-x t t` and `C-x 4 1` bind
`display-buffer-overriding-action` until the next command is over
(`display-buffer-override-next-command`); while it is pending
(`harness-ui-display-override-p`) `harness-ui-display-buffer` skips
positions and the layout and shows the buffer with `pop-to-buffer`
(`harness-ui--display-overridden`), leaving its `harness-ui-position`
as it was, so the next showing goes to its position again.
`harness-ui-session-opener`, `harness-ui-visit-session` (which then
skips its project switch and its "already in sight" shortcut),
`harness-up-to-parent` and `harness-fullscreen` honour it too.  A
command that shows its buffer only once the harness answers --
`harness-switch-session`, `harness-new-session`, `harness-fork-session`
-- takes the selected frame and a copy of the pending action when it
runs (`harness-ui-display-later`) and shows the buffer with them, the
copy bound again only when the original is spent by then
(`harness-ui--call-with-display-override`), so a session picked from a
list fetched later still goes to the frame, window or tab it was asked
for.  `harness-ui-view-p` says whether a buffer is a harness view -- a
harness buffer that is not a session's conversation -- and such a view
is what `q` buries (`harness-ui-quit-view`), which the view major modes
get from the shared `harness-ui-view-map`.

Fullscreen layout (`harness-fullscreen`, `F` on an anchor, `C-c h F`):
an anchor -- an overview (a view that sets `harness-ui-overview-function`:
the task board, the session list) or a main session with no
`:parent-id` (`harness-ui-anchor-p`) -- takes one side of the frame in
a side window (`harness-ui-fullscreen-side`, left by default;
`harness-ui-fullscreen-width`, clamped so the slot keeps a usable
width), and every other window but one, the slot, makes way for it.
The slot shows the session in sight, else the one the anchor names (the
overview function's, at point or the most recent, or a main session's
most recently updated child, BTW conversations aside).  While the
layout lasts the `fullscreen` position is the default: sessions and
views shown without a position take the slot, an overview takes the
anchor side, and `left` and `right` are the slot too, so the frame
never grows a second skinny column; the `slot` position means the slot
when there is a layout.  Once the layout is on, a main session takes
the anchor side only when `harness-fullscreen` puts it there
(`harness-ui--show-anchor`, the ANCHOR argument of
`harness-ui--display-fullscreen`): opened from the board or the session
list, visited, or shown by `C-c h s`, it takes the slot like any
session, so the overview it was opened from stays -- a task's session
is a main session -- while the anchor's own buffer keeps the anchor
side when shown again.  Without a layout, a main session shown in the
`fullscreen` position starts one as its anchor, as an overview does.  After `C-x 5 5` or `C-x t t`
`harness-fullscreen` shows the anchor in the new frame or tab and
starts the layout there (`harness-ui--fullscreen-elsewhere`), rather
than ending or changing this frame's.  A window a popup was displayed in is not taken
for the slot (`harness-ui--popup-window-p`).  The layout is kept per
frame in a weak table (`harness-ui--fullscreen-layouts`), with the
window configuration from before it.  `harness-ui-bury` (`C-c C-z` in a
chat, where plain keys type) puts the slot's buffer away and brings
back the last buffer of the user's the slot showed, keeping the layout;
`q` on the anchor (`harness-ui-quit-view`) ends it, restoring the
configuration, but for a buffer of the user's left in the slot, which
stays in sight.  `q` on any other harness view buries that view instead
(`harness-ui-quit-view`, `harness-ui-view-map`).  A layout whose
anchor's window is gone -- the user closed it, or a project switch
replaced the frame's windows (`harness-ui-visit-session`) -- is dropped
(`harness-ui--fullscreen-drop`), and the buffers it showed get back
the positions they had before it.  The session list shown for the
sessions waiting for you shows in the slot when a layout is on.

Settings page (`harness-ui-config`, `C-c h S`, `harness-settings`):
every harness option on one page, like a customize buffer, about the
project of the current buffer (in a chat buffer, of the session's
working directory).  A Global / Project toggle at the top (`s`, or the
radio buttons, or the header line) picks what is edited: the customize
value, or the project's `.dir-locals.el` (a directory's, outside a
project).  Session defaults, the layered settings, come first in both
scopes; the other options are listed by module in the Global scope and
folded into one line in the Project scope.  Each setting is a
`wid-edit` widget built from its customize type, with its doc and
where its value in effect comes from; toggles, menus and models save
at once, text saves with RET (C-x C-s saves every edit).  A type whose plist
names its keys (`:options`) is drawn as a form: one line per key,
`[X] Base URL: …` with the key's help under it, the key's name width
aligned, and a key the value does not set greyed out with the value it
would start from (`harness-ui-config--present` rewrites the type; the
values it accepts do not change).  In a list, each record folds into a
line summing it up, `[Edit]` opens it into the form and `[Hide]` folds
it again; `[INS]` adds a record, open, from the type's starting value.
[More] unfolds a long documentation, whose first line shows with the
keys' help doing the rest.  A string whose customize type says what it
names, with `:names` (`model` for PROVIDER:MODEL, `provider` for a
provider id, and `:provider ID` for the names provider ID gives its own
models; see `harness-model`), is a dropdown, `harness-ui-config-model`,
alone or with the constants of its menu, in a list too: a button naming
the model, then its id and context window.  The button opens a picker
(`completing-read`) of the UI's catalogue of `provider/models`, grouped
by provider and annotated with context window and price.  Text that
matches no candidate is taken as typed, and a model no provider lists
gets a warning line.  [Remove override]
deletes a project value, [Reset to default] a customized global one.
Secrets show as set or not and are set through `read-passwd`; long
texts open in `string-edit`.  The page reloads on `config/changed`,
keeping edits not saved yet, point, and the records left open.
A setting the policy sets ([policy.md](policy.md), `:locked` in
`config/describe`) is drawn with its value, a lock and "Locked", and
"set by policy in FILE" under its doc, in both scopes: no widget, no
[Remove override] or [Reset to default], and the commands that would
change it (`C-c C-c`, `d`) refuse with the reason.  A banner under the
scope lists everything `:policy` sets, options the page does not show
included ("not on this page"), and Advanced's count of changed
settings leaves locked ones out.

Session settings: `harness-set-model`, `-thinking`, `-permission-mode`
and `harness-toggle-non-interactive` (`C-c h m` `T` `p` `i`) change what
the buffer's `harness-ui-setting-target-function` names -- a session
id, or `(VALUES SET-FN &optional CONTEXT)`: the settings it holds, the
function that stores one and the words saying whom it is for, which is
how the task board answers for the next task and the session list for
its marked sessions -- and otherwise the current
session.  The menu's `i` entry says whether that is non-interactive
("Non-interactive: on"), and has no state where the command would
ask for a session.

The all-sessions commands, `harness-set-model-all`,
`harness-set-thinking-all`, `harness-set-non-interactive-all` and
`harness-set-supervisor-all`
(`C-c h M` `H` `I`, the menu's "Session settings" column, where the
supervisor one is V beside I; see also supervisor), reach every
project.  They change the sessions first, every active one and those of
the current tasks (`harness-ui--everything-filter`, `(:active t :tasks
t)`, through `session/set-all`, or `handoff/switch-all` for a model so
no lossy switch escapes the handoff), then the current tasks of every
project (`task/set-all` without `:cwd`), whose sessions hold the value
by then and so are not changed or told twice
(`harness-ui--apply-everywhere`).  A session whose task is completed,
in the board's done column, is left alone by all of them, even an
active one: the selection subtracts the done tasks' sessions
(`session/select`), and `task/set-all` never touches review, done or
archived tasks.  `harness-ui-set-all-functions` lets
what starts later follow, and returns the directories it changed
something for: the task board's `harness-ui-tasks--set-all` sets the
new-task settings of every open board -- for a model or a thinking
level only when the default changes, for non-interactive always.
Unless a prefix argument says otherwise the value becomes the global
default (`config/set` `:scope global`; for non-interactive only after
the tasks changed, since a task without a setting of its own follows the
default and is compared with how it would have started; the supervisor
one sets `harness-supervisor` and `harness-supervisor-tasks` and has no
task records to change).  Then they say
how many sessions and tasks changed and, from `config/overrides` (with
the boards' directories), what keeps new work from following: the
projects whose `.dir-locals.el` sets the key otherwise, at the project
or the directory layer, and the task default that wins over it.  A
model or a thinking level reports that when the default changed;
non-interactive and supervisor mode also whenever they are turned off.
None of them rewrites
a `.dir-locals.el`.

`harness-set-priority-all` (`C-c h Y', "Priority for all sessions…" in
the menu's "Priority" column, the four priority entries' own, beside
"Session settings") is the fourth of them, and the simplest: a
priority is the session's, a task's included, so it is one call to
`_harness/priority/set-all {priority, filter}' with the same
`harness-ui--everything-filter' -- every current session and every
current task's session, of every project, at once -- and no task record
is touched at all.  The method leaves out the sessions already
carrying that level of their own, and the command says how many
changed.  It sets no default for later work: a task submitted
afterwards is submitted with the board's next-task priority, which the
board's own button picks (see the task board).

The session list reaches the same methods with a narrower filter: with
sessions marked in it, the setting commands and `p` change those
sessions (`(:ids IDS)`) and the tasks they work on (`task/set-all` with
the tasks' ids), and nothing else.  They set no default for later work
and leave the new-task settings of the boards as they are (see the
session list, below).

A model switch asks the harness first (`handoff/check`, or
`handoff/check-all` for `harness-set-model-all`, which asks once for the
whole batch).  A lossy one asks how to hand over through
`harness-ui-switch-function`: with the `ui-switch` module the question is
a banner above the session's compose box -- the chat panel the review
banner uses (`harness-chat-panel-functions`) -- with the two models, the
reason, the risks, the cache cost and the running turn as labelled rows,
and one button per choice (current model summarises, new model
summarises a limited context, full transcript, no handoff, cancel).
Summarising on the current model is cheap while its prompt cache lasts
("warm cache"); once `handoff/check`'s `:cache` lapsed, or belongs to
another model, the choice says so instead ("cache expired at 14:07:
re-reads it all uncached", "cache cold: …", and for a batch how many
lapsed), in the banner and the minibuffer alike
(`harness-ui--handoff-choices-for`).  For one session whose cache a
redaction dropped (`:cache` has `:dropped`, see `session/reset-provider`)
it says so, as the cache panel does: "cache dropped at 14:07 by a
redaction: re-reads it all uncached".  Its
keys answer while point is on the banner and a click answers from
anywhere; the banner says the handoff is lossy and the new model is told
to re-investigate.  Without a chat buffer to show it in (a switch asked
for outside the UI, or over ACP) the minibuffer question of
`harness-ui--read-handoff` asks instead.  The answer goes to
`handoff/switch` (`handoff/switch-all`); cancelling changes nothing, not
even the default for new sessions.  A switch that loses nothing goes
through `session/set_model` (`session/set-all`) as before, and so does
any switch when the harness cannot check.

Desktop notifications: `harness-ui` answers `_harness/client/notify` by
showing the notification on this Emacs's desktop
(`harness-notifications-desktop-notify`), with `{backend}` once it
shows or an error when it cannot.  One about a session or a task can be
clicked; the click, out of the process filter or D-Bus handler, brings
a graphical frame of this Emacs to the front and runs
`harness-ui-notification-functions` (the wire plist; the first that
returns non-nil has shown what it is about), else opens its session in
its project (`harness-ui-visit-session`, which switches to the project
first, as a row of the session list does).  The task board's function
switches to the task's project first (`harness-ui-switch-to-project`
with the main checkout of the notification's session, else of its
`:project`; a switch that fails, or none being configured, does not keep
the board from opening), then opens the board of the notification's
`:project` with point on the task's card, once the board shows it
(within 10 s).  A click on a terminal-notifier notification this Emacs
no longer knows (`harness-notifications-desktop-unknown-click-function`,
set by `harness-ui--init` unless already set) brings a graphical frame
to the front and lists the sessions waiting for the user
(`harness-ui-notify-show-waiting`), else the session list.
`harness-test-notifications` (menu `N`) sends a test
notification through `_harness/notification/send` and says in the
echo area what each provider did with it.

Remote control page (`harness-ui-acp-remote`, `C-c h P`,
`harness-remote-control`): whether the harness serves other devices
(start or stop), the ACP address their clients connect to, the address
of this machine in it (chosen among the interfaces), whether what devices
send is encrypted (an https `harness-acp-remote-public-url`, or a VPN
address; else a warning), the ways a device can sign in (approval in Emacs,
and the OpenID Connect sign-in link when the provider is set up), the
devices that wait to be approved, each with its name, address, the web page
it comes from if it is one, the code to compare and `[approve]` / `[deny]`
(`y` and `n`), and the signed-in devices, each with its name, address, how it
signed in, when it was seen and when its session ends or that it lasts as long as
its connection (`k` revokes the one at point, `K` all), and `t` (`[make a token]`)
makes a token for a client that cannot sign in itself, shown once in a buffer of
its own.  The UI follows `acp/remote-changed`: a new request is announced in
the echo area, counted in the mode line notifier (a segment on
`harness-ui-notify-segment-functions`, a click runs `harness-remote-approve`,
also `C-c h y`, which asks which device when several wait and the user to
confirm) and, through the harness, by a desktop notification.  In corporate mode
the page shows a notice only.  The QR encoder `harness-ui-qr` is no longer used
by it.

Secrets and redactions (`harness-ui-secrets`, module `ui-secrets`, menu
`x` and `E` after Log in the Tools column): `harness-redact-secret`
asks where the secret is -- a JSON path in a file, chosen from the keys
and types `_harness/secrets/shape` gives and never from values; a file
and a regexp with one capture group; a variable of the harness; a
command whose output it is; or the value itself, typed with
`read-passwd` and sent only to a harness on this machine
(`harness-ui-secrets--local-p`: this Emacs's own, its child process, or
a loopback address), then cleared with `clear-string` once the last
answer is in -- a label (by default from the path), the sessions (all,
the project's, this session and its forks, or ids) and a reason.  It
asks `_harness/secrets/redact` with `:mode "scan"` and `:origin (:kind
"user")`, shows the report in `*harness redaction*`
(`harness-ui-secrets-report-mode`: counts and ids, never a snippet), asks
`yes-or-no-p`, and asks again with `:mode "redact"`.  The question ends
with what the reset costs in prompt cache when the scan says some would
go (`harness-ui-secrets--cache-cost`): "; 2 provider conversations start
over, dropping ~126k tokens of prompt cache", from the sessions with
`:cache-would-drop` and their `:context`.  The requests have
no deadline: the harness vacuums a large search index before it
answers.  `harness-secrets-add-source` asks `_harness/secrets/add-source`
for the same kinds of source but the typed value (that would put it on
disk), `harness-secrets-list-sources` shows `_harness/secrets/sources` in
`*harness secrets*` (`a` adds, `d` stops masking the source at point,
`g` reads again, `l` lists redactions), and `harness-redactions` shows
`_harness/secrets/log` in `*harness redactions*` (`RET` shows one
whole).  The module follows two events.  `session/redacted` loads the
chat of that session again, which draws the nodes as they are stored now
and the hint the redaction wrote.  `secrets/redacted` is for the
buffers the harness cannot reach: `*harness-log*` (the harness's log
lines are copied into it), `*Messages*` and every `*harness…` buffer
that visits no file (`harness-ui-secrets--log-buffers`).  A typed value
and a command's output (run again here, for a harness on this machine)
are cleaned at once; for a file or a variable this Emacs reads the
secret itself (`harness-redaction-resolve`), and cleans only when each
secret it reads has a fingerprint the harness redacted
(`harness-ui-secrets--matching`).  A harness on another machine reads
other files, so it is not followed.

Version page (`harness-ui-version`, `C-c h v`, `harness-version`): the
verdict, the commit running (with, when the harness runs in its own
process, the commit this Emacs loaded the UI from, and a reload button
when the two differ), each origin with its commit and status (the
repository the loaded checkout pulls from says so), the commits the
harness lacks (an origin at the same commit with the same status as one
listed above says so instead of listing them again; an ahead one has
none to list), and the update: an `[Update harness]` button (`u`) when
this Emacs can reload the harness it shows, the last update's outcome
(`harness--last-update`), with how long ago it settled, and, for one
that brought commits, its changelog.  A commit is shown as its message,
subject and body, never its diff or file statistics.  The button runs
`harness-update': a checkout straight.el has a recipe for is pulled with
`straight-pull-package', the way its package manager updates it, and put
back with `git reset --keep' when the commit it lands on fails the
check.  The package is the name its recipe gave it, which
`harness--straight-package` reads from straight.el's own records
(`straight--repo-cache` and `straight--recipe-cache`, by the recipe's
`:local-repo`, the clone's directory) and is not always the directory's
name -- `(package! harness ...)` is the package `harness` in the clone
`emacs-agent-harness/` -- because `straight-pull-package` given a name
it has no recipe for does nothing, silently, and returns nil as it does
when it pulls.  So an unmoved clone proves nothing, and one that
straight.el has no recipe for is not pulled by it at all: both are
fetched by the remote and branch `harness-revision-remote' resolves,
like any other checkout, and fast-forwarded to the commit it names,
checked first by another Emacs.  "Up to date" is therefore said only
once that remote was asked, and only when the harness runs what the
checkout holds: a checkout can move on by itself (a package manager's
pull, or one by hand) while the harness runs the commit it was loaded
from, and with nothing new from the remote `harness--updated` then
reloads, as it does for commits that came in, when the commit this Emacs
noted on loading (`harness-revision--loaded`, of the same checkout) is
not the checkout's -- the outcome is "updated", with a count of none.
A detached HEAD, or a checkout with no remote, is refused with a message
that says so.  What to do without updating is said too: reload when the
loaded checkout moved on, push when only a local checkout has them.  The
page follows `harness-update-hook', which `harness-update' runs with the
outcome as it settles, and redraws.
Opening it shows the last report at once and asks `version/check` with
a max-age of a minute; `g` asks with 0; `version/checked` redraws it,
and the menu's Version entry says "not the latest" after a report that
found the harness behind.  So does a nag icon (`harness-icon-update`,
an arrow up in a circle, in `harness-caution-face`;
`harness-ui-version-nag`) in the places `harness-ui-version-nag-places`
names: the mode line notifier after its "harness"
(`harness-ui-notify-segment-functions`, which keeps the notifier
showing with no session active), a chat's header line before [menu]
(`harness-chat-header-end-functions`) and the board's
(`harness-ui-tasks-header-functions`), both after the pet's face and
at priority 65, so in a narrow window it goes after a chat's model,
and before a chat's name and the board's spend.  Its `help-echo` names the origins with commits the harness
lacks; a click runs `harness-version`; it has no `mouse-face`, which
would box the image.  `harness/reloaded` hides it until the next
`version/checked` (`harness-ui-version-behind-p`: the report is about
the commit that ran before), and connecting to a harness forgets the
last one's report and asks `version/report` when no page shows (a page
asks `version/check`); an answer arriving after an announced report is
dropped.  The places redraw when the icon comes or goes
(`harness-ui-version--nag-changed`); a reload of the file adds its
hooks again, as the module is not initialised again.

Task board (`harness-ui-tasks`, `C-c h a`): the project's tasks in seven
sections -- requires your input, ready for review, merging, in progress,
pending, backlog, completed -- with each card's current todo, progress, how
long it has worked or waited and merge state (what its session has to say
-- context in use, tokens written, average output rate, cost -- is in the
tooltip of its title, made when you hover),
one-click answers to a blocked task's question or
permission, and a compose box that submits a task, edits a pending one,
messages a task's session, answers its question or takes the feedback
that sends a task back from review (`C-g` leaves an edit, message,
answer or feedback for a new task again: a question stays waiting,
never cancelled).  The board is a panel of the box
(`harness-compose-panel` `board`): its letters type in the box, so
`C-c . F` and the rest press them from there -- the empty box and the
prompt's tooltip say so -- while a key for the task at point, which
needs a card, says it has nothing to act on from the box.  `@` on a
card (`harness-ui-tasks-attach`) attaches that card's task to the box
(`harness-compose-attach-task`), whatever the box is for: a new task, a
message, feedback; an answer, which is text only, carries the
reference.  The same box does all of these, so what `C-c C-c`
will do is made plain: a box that sends to an existing session -- a
message, an answer, feedback on a write-up, or feedback that sends a
task back from review -- wears the message colours
(`harness-compose-message-face`, with the prompt and a bar in
`harness-compose-message-accent-face`, carried onto the label line and
the [cancel] beside it), shows the message icon and names where it
sends ("Message to session “X”", "Refine “X” with feedback",
"Answer “…”", "Send back “X” with feedback");
composing a task, new or edited, keeps the plain box.  A task in
review shows [Verify] and [Send back]: `v`
accepts the work (its branch then merges), `R` sends it back to its
session with the feedback written in the compose box (`C-u R` reads it
in the minibuffer); `m`, a message, opens the same box, since any
message to a task in review sends it back.  A verified task waits in
merging -- queued for the queue's turn, merging, or its session
resolving the conflicts -- saying so on its card until the branch is in
and it moves to completed.  A card of a task that handed a report in
also shows [Review], popping the report out; it is one of the items
`harness-ui-popout-at-point-functions' offers.  While the task waits
for review, the report ends with the banner of its session, [Verify]
and [Send back], and a box for the feedback.  Ready for review's
heading counts the tasks to review, as each column's heading counts its
own, and `task/review` says in the echo area that one is ready
(`harness-ui-tasks--notify-review`).  The mode line notifier counts
them too, every project's, whatever board is open: the module adds
`harness-ui-tasks--notify-segment` to
`harness-ui-notify-segment-functions` (after the version page's nag),
the review flag and the count in `harness-notify-review-face`, from
`harness-ui-tasks--in-review`, the views of the tasks whose column is
review and that are not archived.  `_harness/task/list` without a cwd
fills it as the UI connects (and as the module starts while connected),
then `task/changed` and `task/deleted` keep it, the notifier drawn again
only when the count changes.  Its tooltip says how many each project
has; a click runs `harness-tasks-review`, which opens the board of the
current project (`harness-ui-tasks--current-project`) when it has tasks
in review, else of the project whose task finished last, point on that
project's newest review card, after switching to the project as a
notification's click does (`harness-ui-tasks-visit-task`, which both
share).  The header line holds only what
the board does not show: the project, and, as a chat's does for its
session, what the board's tasks cost and who pays (see Cost display
below), then the fullest budget that applies to the project, then the
board's buttons.  `V` turns review off and on again for every project
(`harness-tasks-require-verification`, saved through `config/set`, the
option the settings page has under Task board):
off, finished tasks merge and complete by themselves, and Ready for
review shows only while tasks from before still wait there; turning it
off while tasks of the board wait for review offers to verify them.
The settings line under the New task label ends, in every mode, with
how many of a project's tasks work at once, a button: `N at a time`, or
`all at once` without a limit, in `harness-task-held-face` at 0, when
no task starts by itself.  A click reads another limit in the
minibuffer (a number or `no limit`, the limit now the default; an
answer that is neither changes nothing) and saves it the same way
(`harness-ui-tasks-set-max-running`, `harness-tasks-max-running`); the
harness starts the waiting tasks a higher limit lets through at once.
On a narrow board the settings before the button shorten first, down to
`harness-ui-tasks--min-settings-room` columns, so the button stays
whole.  `config/changed` brings every board the new values.  RET opens the session, and
`C-c h a` there leads back to the open board listing its task, whatever
directory the session works in; elsewhere a task's worktree belongs to
the main checkout's board (`harness-files-main-root`).  Redraws, after
every change and on every tick of the clock, leave point and each
window where they were: on the same line of the same card (its buttons
are on the second), on the same button, on the same line above the
box; never on another button.  Any click on a button pushes it, a slow
one too, rather than reaching the board's own click, which opens the
session.  The session setting commands change the task at point, or
from the compose box the settings the next task starts with (shown as
buttons under the New task label), and so does the worktree switch
beside them: `own worktree` (the default in a git project) or `main
tree`, where the next task works in the project's own checkout, with
nothing to merge (`harness-ui-tasks-toggle-main-tree`; new tasks only).  While the harness has the supervisor module the line also
shows the supervisor switch (`supervisor`, or `hands-on' once turned
off, `harness-toggle-supervisor'): the setting of the next task's
session, sent with the
task and applied to its session when it starts.  The harness says
whether it has the module by carrying `:supervisor' in `task/settings';
without it there is no button.  Plan's settings line has none either
(`harness-ui-tasks--work-supervisor-p`): a planned task works hands-on,
so it is sent without the setting, and the step setter of a write-up,
a plan or a planned task's work refuses `:supervisor` with a
`user-error` saying why, which is what `harness-toggle-supervisor`
shows in Plan.  A
Submit / Refine / Plan switch beside that label, showing only the
current mode (`harness-ui-tasks--mode`; a click or `C-c C-t`,
`harness-ui-tasks-cycle-mode`, goes to the next, `C-u C-c C-t` reads
one; `harness-ui-tasks-toggle-refine` is its obsolete alias), picks
what a new task does: start, or go to the backlog, written up by an
agent (Refine) or planned by a strong model (Plan, `:plan t`), and
wait in the backlog -- its own section, which the queue never
starts -- until you start it (`s`).  The lines above the box are the
current mode's alone.  A step has a model and a thinking level of its
own and nothing else (`harness-ui-tasks--step-buttons`): in Refine and
Plan a line per step holds its name and those two buttons, and nothing
else -- the step before the work (`harness-ui-tasks--step-line`,
`refine` or `plan`), then the work (`harness-ui-tasks--work-line`,
`work`) -- and the settings line below them holds the task's
own, whatever the step: permission mode, non-interactive, the
supervisor switch, the worktree switch, then the max-running button.
Submit has the settings line alone, starting with the work's model
and thinking level.
No sentence says what a mode does: not those lines, not the empty
box's placeholder (`Describe a task…` in every mode), and not a
message when the mode changes; the toggle's tooltip does, in a few
words, and a card being written up or planned says `writing it up…` or
`planning…`.  The steps' choices are keys of
`harness-ui-tasks--new` (`harness-ui-tasks--step-keys`:
`:refine-model'/`:refine-thinking', `:plan-model'/`:plan-thinking',
`:plan-work-model'/`:plan-work-thinking'), seeded from
`task/settings`; a step's button binds `harness-ui-tasks--step` around
the setting command, so `harness-ui-tasks--setting-target` sets that
step's keys, while the setting commands typed in the box, and the
buttons of the `work` line, set the work's.  A step's target
(`harness-ui-tasks--step-target`) gives `harness-ui--setting-set` a
function of the key as the CONTEXT of its message: the step's own for
`:model'/`:thinking' ("for the plan of new tasks"), "for new tasks"
for the rest, which every step shares.  `task/submit` then gets the first step's as
`:refine-model'/`:refine-thinking' and the work's as
`:model'/`:thinking'.  A board whose harness offers no `:plan-model'
refuses to submit in Plan rather than start the task at once.  The
max-running button ends the settings line in every mode: a
write-up or a plan takes no slot, the limit counting the tasks at
work.  `r` refines a queued task,
retries a stopped write-up, writes one up all the same when it refused
the task as a duplicate, or sends feedback on a backlog task's.  Right
after its count, the Backlog's heading has the project's backlog mode
as a switch, [Manual queue] or [Auto queue]
(`harness-ui-tasks--backlog-mode-button`, from `task/settings`'s
`:backlog-mode`): a click or `W` (`harness-ui-tasks-toggle-backlog-mode`)
shows the other mode at once and sends `_harness/task/set-backlog-mode`,
and every board of the project follows its `task/backlog-mode` event.
No note follows a switch: what a mode does is in its tooltip.  The
Pending heading has the queue's switch in the same place, [Queue:
running] or, in the attention face, [Queue: suspended]
(`harness-ui-tasks--queue-button`, from `task/settings`'s
`:queue-suspended`): a click or `P` (`harness-ui-tasks-toggle-queue`)
shows the other state at once and sends `_harness/task/toggle-queue`,
and every board follows its `task/queue` event.  Neither switch is in
the header line, nor pushed to the right edge, where [Archive all]
ends the Completed heading.  A task
whose write-up refused it as a duplicate shows it in Requires your
input, naming the task it duplicates and saying why: `k` drops it, `r`
writes it up anyway, `m` takes what makes it another task than the one
it duplicates.  Beside the Submit / Refine / Plan switch, the priority button
(`medium priority`, `harness-ui-tasks-cycle-new-priority`) cycles the
next task's priority through high and low and back; it is a setting of
the board like the others, sent as `task/submit`'s `:priority`.  The
board has no mode for changing many tasks at once: that is the session
list's, which changes the sessions marked in it and the tasks they work
on (below).  `+` and `-` on a card raise and lower its task's priority
(`harness-ui-tasks-raise-priority` / `-lower-priority`), which is its
session's: they send `_harness/priority/set {sessionId, priority}' with
the task's session -- a waiting task's included, since it has one from
submission (a completed task refuses, as it no longer waits), and the
board follows `session/ext-changed' for the priority's key -- the
harness announces a session setting rather than only returning it --
and re-reads the tasks, so the card shows the new level.  The card's
menu entries do the same, offered while the task has not started and it
is not at the end of the range.  A high task wears `↑`
(`harness-icon-task-priority-high`) before its title and a low one
`↓`, and that is all: no words among its facts repeat it (the faces
`harness-task-priority-high-face` / `-low-face` are the compose box'); medium shows nothing.  A
pending card's "queued X ago" counts from when the task joined the
queue (`harness-ui-tasks--queued-since`: `:queued-at`, else
`:returned`, else `:created`).  `I` or
[Add session] makes an ongoing session a task.  A card's menu
(`mouse-3`) has the actions of its column, then those the functions
of `harness-ui-tasks-action-functions` add for it: each is called with
the task and returns (LABEL COMMAND) entries, whose command runs with
point on the card (`harness-ui-tasks-task-at-point`,
`harness-ui-tasks-request`).  They are never one of the card's
buttons (`harness-ui-tasks--actions` with OWN), and a function that
fails adds nothing.  The harness repository's own plugin adds Open
harness this way (ui-tools-dev, `harness-ui-tools-dev-open-harness`)
for a card in Ready for review whose worktree is itself a checkout of
the harness: it starts the worktree's own live development loop in an
Emacs of its own, frame raised, through `harness-dev/open`, so the
work can be tried before it is verified.  That instance stops once the
task is done, archived or deleted (see tools-dev).  `b` or [BTW] (or the
usual BTW command) opens a BTW side conversation over the board about
its tasks (`task/btw CWD &optional NAME MODEL`): a new `btw` session at
the project root, on `harness-btw-model` applied to `harness-model` as
configured there (the simple tier of its provider, by default) or, for
that conversation alone, on MODEL, which `C-u b` reads from the catalogue
and the board's start function sends as `model` to `_harness/task/btw`
only when one was chosen.  `SPC` over a card, or [Answer…] / [Request…]
on it, pops out what the task at point needs -- the permission prompt or
question its session waits on, a task's report -- through the shared
`harness-ui-popout-at-point`, which runs whichever view of the item
registered for it.  The board reads what a session waits on through
`harness-ui-pending`, its shared notion of it.
Other modules add to the board's header line through
`harness-ui-tasks-header-functions`, before [BTW].  The plain strings
they return join into one segment ([Search]).  A `(TEXT PRIORITY MIN)`
becomes a segment of its own, which the board separates from the rest
and which makes room as PRIORITY says (the companion pet's face and
name, at 15, before [Add session]).  A module can draw at the right of
the lines between the cards and the compose box (the error, the compose
label, the settings) through
`harness-ui-tasks-corner-functions`.  Each function is called whenever
those lines are drawn, with the columns they have and the columns each
takes whole, and cannot move point.  The first that answers returns
`(:beside ROWS :reserve COLUMNS :above LINES)`: ROWS end the first
lines, which are fitted to the room left after COLUMNS, and LINES go
whole above them all.  The lines stay together above the box, and the
board fits its cards to the room they leave.
`harness-ui-tasks-redraw-tail-lines` draws those lines again, the box
left alone, when a module's corner would change (the companion pet's
figure).
A section's cards are laid out together (`harness-ui-tasks--card-parts`
takes each card apart, `harness-ui-tasks--layout` finds the section's
columns): the titles start at one column, the facts stand in a
right-aligned column per kind (`harness-ui-tasks--fact-kinds`: archived,
main tree, borrowed slot, merge, todos, time), as wide as the widest of
the section's, and the buttons start at one column.  Each column starts
with a space `:align-to` its place, so an icon or an arrow drawn wider or
narrower than its character moves nothing after it.  The title comes
first: a row states little, and the session's context, tokens, rate and
cost are in the tooltip of the title (`harness-ui-tasks--title-help`, a
`help-echo` function: made when it is asked for, so the board is not
drawn again for figures that change with every model call -- the board
key holds a session's name, status, todos and requests only).  What a
row does state gives way to the title, a card at a time
(`harness-ui-tasks--plan`): the todo count first, then the time, both
informational (`harness-ui-tasks--fact-give-up`); the state flags stay.
A title that still would not fit beside the buttons has the line to
itself: the card's facts and buttons go together to a second line, in the
same columns (a card that shows its recap already has its buttons there,
and leaves out its state too, last of all).  A column no card has room
for is not laid out, and a title is cut only when it is longer than the
window.  A card that waits for review is the one with a third button,
[Review Changes] or [No report]; the report is `SPC` away on any other.
A board taller than its window
holds its least urgent cards back behind `… N more  [Show all]`; a
section opened with [Show all] keeps its [Show fewer] only while folding
it would hold cards back (`harness-ui-tasks--moot-expansions` forgets
an expansion once its list fits).  A button pushed on a card is held
down at once (`harness-task-button-pressed-face`) until the requests
its command makes are answered or fail, no sooner than
`harness-ui-tasks--pressed-min-seconds` (0.3) and no later than
`-max-seconds` (15) after the push; a second push meanwhile only says
so, and a key typed on a card holds that card's button of the same
command (`harness-ui-tasks--press`).  The clock that redraws the visible
boards for their elapsed times (`harness-ui-tasks--tick`, every
`harness-ui-tasks--tick-interval` seconds) then runs
`harness-ui-tasks-tick-hook`, so a view whose times run as the board's
needs no timer of its own.  `S` opens the project's task slots page
(below).  Boards reload after any
task, merge, turn, status, worktree, budget or reload event.  New tasks show at
the top of in progress (latest started first), review lists the latest
finished first and completed the latest completed (verified, else
finished) first; merging is the queue's own order, from when each
branch joined it; pending is the queue, in the order its tasks start
(`harness-ui-tasks--starts-before-p`, which reads
`harness-tasks--start-order` off the views -- `:priority`, `:sent-back`,
`:returned`, `:created` -- since a board may show a remote harness):
the highest priority first, and within one the work sent back from
review, then the tasks returned to the queue (paused, pre-empted, their
borrowed slot taken back), the first returned first, then the oldest;
each card's place in line counts down that order.  The backlog and
Requires your input go by priority, then the oldest
(`harness-ui-tasks--ranks-before-p`); only queued tasks have a place in
line.

The board's search (`harness-ui-tasks-search`, `/` on the board,
[Search] in its header, `C-c h /` on a board) turns the board's compose
box into a search box (`harness-tasks-search`) instead of reading the
line in the minibuffer: the box's target becomes `(search)`
(`harness-ui-tasks--target`, `harness-ui-tasks--searching-p`), its label
says what it does with a `[cancel]` button, and it wears colours of its
own (`harness-task-search-box-face` and its accent), as a message's box
does.  What the box held -- its text, its attachments and its target, a
new task, an edit or a message -- waits aside
(`harness-ui-tasks-search--draft`) and comes back once the search is
sent or `C-g` closes the box (`harness-ui-tasks-search-leave`); the box
turning to another target ends the search
(`harness-ui-tasks-search-end`).  The keys of the box are the quick
search's (`harness-quick-search-box-mode`, below): `RET` sends the line
to `harness-ui-tasks-search-submit`, where an empty line does what the
search proposes, and `M-p`/`M-n` go through `harness-quick-search-history`,
the one history of the board's searches and the quick search's.
The line goes to `_harness/search/ask` favouring tasks, with where it was
typed (`harness-quick-search-context`) and the catalogue of commands
(`harness-quick-search-commands`); the board then shows only the tasks
the answer is about, archived ones included, under a banner that says
the line, what it matched ("1 task · 2 sessions · 1 command", or "no
task matches") and what the model looked at besides the board.  The
banner goes on with the answer's note, the sessions it names and the
commands (at most four of each, then "... N more"), each drawn as the
quick search draws it (`harness-quick-search-session-line`,
`-command-line`) with the board's buttons: [Open], which opens a session
found in a transcript at its match, as the quick search's does (below),
[Run], [Describe].  A search that found nothing is widened by the search
method, and the note says so.  `harness-ui-tasks-filter` carries the
banner: `:show` a predicate over a task, `:banner` a function returning
the text above the columns, `:clear` the function that drops it, which
`C-g` on the board runs when the compose box has nothing to leave
([Clear] does too).  The columns left without a task are hidden.  An
action the answer does not need confirmed runs at once, and the banner
and the echo area say what it did (the toast), with [Undo] when it can
be undone (archive and restore
undo each other, and a new priority goes back to the old one: "Made “A”
high priority"); `task/search-apply` runs them.  An action that
interrupts work, merges it or sends words to an agent is proposed
instead: the banner asks, with a button that does it and [Skip], and `/`
then RET on the empty box does it too (the box's placeholder names what
an empty line would do).  The header's [Search] segment spins while the
model works, and each search box opens with `_harness/search/warm`
so its process is started before the line is typed; the model's name
shows while it answers.  The best match gets point once the board shows
it (`harness-ui-tasks--focus`).  `harness-ui-tasks-search-show-plan`
shows a plan on the board without searching, which the quick search's
[Board] uses.

Quick search (`harness-ui-quick-search`, `C-c h /` anywhere but on a
board, `/` in the `C-c h ?` menu, `harness-quick-search`): a popout
(`harness-ui-popout`, KEY `(quick-search)`) at the bottom of the frame,
opened from any buffer, whose shared compose box takes the line to
search (`harness-quick-search-box-mode`: `RET` in the box calls
`harness-quick-search-box-function` with the trimmed text, `M-p`/`M-n`
walk `harness-quick-search-history`, and outside the box the keys are the
buffer's own; `C-c C-c` sends too).  The line stays in the box.  It goes
to `_harness/search/ask` with `:context` (`harness-quick-search-context`:
the view of the buffer the popout was opened from -- board, chat,
session list, conversation tree, settings or other -- its title and mode,
the session of a chat, which the answer leaves out, and the project),
`:bias` (`harness-quick-search-bias`: tasks on a board, sessions in the
session list and the conversation tree, commands elsewhere) and
`:commands`, the catalogue (`harness-quick-search-commands`): the
harness menu's own commands, the keys under `harness-ui-prefix-key`, the
`harness-menu-group` of every mode and every other interactive
`harness-*` command, each with the keys it has in the buffer, where it
applies, what the menu calls it, the first line of its documentation and
whether it runs there.  What takes long in it does not depend on the
buffer: the walk over every symbol of Emacs that finds the modes and the
commands, which grows with each package loaded (some 20 ms in a plain
Emacs, a tenth of a second in a big one), and each command's first line
of documentation.  They are one scan
(`harness-quick-search--scan-cache`) built ahead: the module's init
schedules an idle timer (`harness-quick-search--idle-delay`, a second)
that builds it in `while-no-input`, so typing stops the build and the
next idle moment starts again; `after-load-functions` marks the scan
stale and schedules one rebuild (at most one timer waits), the stale
scan serving until then, so a command defined a moment ago may be
missing for a few seconds; only a search that finds no scan at all
builds one on the spot, and the module's shutdown unhooks, cancels the
timer and forgets the scan.  A build must not ask for another, or a UI
left alone would run it again and again and Emacs would read no socket
in between (see Processes): reading the documentation of a command
loads its library again when the library's .elc changed since it was
loaded, and at every read for a command the new .elc no longer has, which
a hot reload leaves defined, so the loads a build makes are its own and
mark nothing stale (`harness-quick-search--scanning`), and builds begin
`harness-quick-search--min-interval` (5 s) apart at least: within the
interval the timer is an ordinary one, which sets the idle timer when it
is due, since an idle timer is ripe the moment Emacs has been idle long
enough.  A search does only what its buffer decides, from the
scan: the menu's suffixes, the keys under the prefix, the modes' groups,
the `:here` flags and the keys it binds (a few milliseconds).  The
popout draws where the search was opened from and what it favours, the
line and what it found, a note ("widened", with a caution icon, when the
search added the nearest) and a heading for each kind in the order the
bias suggests -- Commands (keys, what it does, name and where it
applies, [Run] when it runs where the search was opened, [Describe]),
Sessions ([All matches] on the heading; for each: status, name, kind,
project, when it was active, [Open] and, dim under it, the passage the
search found), Tasks (id, title, state, [Board]) -- then
[Search sessions] and [Search commands], which ask the line again with
that bias.  [Run] closes the popout and calls the command interactively
in the window and buffer the search was opened from; only an interned
`harness-*` command runs.  [Open] is `harness-quick-search-open-session`
on the session's entry of the plan: it closes the popout and calls
`harness-ui-search-visit` (see session-search) with the entry's `:node`
and the regexp `harness-ui-search-hit-regexp` makes of its `:snippet`
and `:ranges`, so a session found in a transcript opens at the message
that matched, point on the words found, highlighted; one found by its
name opens as the session list opens it.  The module requires ui-search
for this.  [All matches] is `harness-quick-search-all-matches`: it
closes the popout and runs `harness-search-sessions` (C-c h g) for the
words the search looked for in the sessions, the plan's `:session-query`
(the line as typed when it has none), the session search's own view of
every session that matches, with its snippets.
[Board] opens the task board with the found tasks shown, and the actions
of the answer are proposed with [Do it] and [Skip]: nothing is done
unasked.  A search that found nothing even widened says "Nothing found".
Answers carry the search's number and a popout drops those of an earlier
search.

Task slots page (`harness-ui-slots`, `harness-slots`: `S` on a board
for its project -- `harness-ui-tasks-slots`, which names the module
when it is not loaded -- `C-c h Q` and the menu's `Q` for the current one;
`*harness slots*`, `harness-ui-slots-mode`): the answer of
`_harness/task/slots` drawn as a box for each slot -- the ones in use
first, the longest at work first, each with its task's title, its
priority's arrow and border face, its state and for how long; then the
free ones (at most `harness-ui-slots--max-free`); holders past a lowered
limit are marked over it -- then the queue's waits by priority (how
many, the longest and the average so far), the next five in line, and
the recorded waits of the last `:days` days by priority (how many
started, their average and longest).  `RET` or a click on a box opens
its task's session (`harness-ui-session-opener`), `TAB` and `S-TAB` go
from box to box, `l` or [Set limit] is the board's
`harness-ui-tasks-set-max-running`.  Every column and border is placed
with `(space :align-to COLUMN)`.  The page is a function of the answer,
the width of its widest window and the time
(`harness-ui-slots--page`); `harness-ui-slots--render` draws it only
when that text differs from what is drawn, keeping point on the same
box or line and each window's start.  It keeps up without churn: after
the events a board reloads on (`harness-ui-tasks--refresh-events`),
`task/changed`, `task/deleted` and a change of a session's priority
(`session/ext-changed` for its key), a page a window shows asks again
once the burst settles (`harness-ui-slots--refetch-delay`, 0.5 s), and
a hidden one is only marked stale, asking once a window shows it again
(`window-buffer-change-functions`); its times run on the boards' clock
(`harness-ui-tasks-tick-hook`), drawn from the answer it has; an answer
to an older request than the last is dropped.

Companion pet (`harness-ui-pet`, `C-c h z`, `harness-pet`, menu `z`):
the buffer `*harness pet*`, and a few places besides.  Before it
hatches: the egg, [Hatch it] (`h`) and what hatching does.  After: a
card with its stars, rarity and species, the creature in its rarity's
colour (`harness-ui-pet-art SPECIES EYE HAT FRAME`: five lines, three
frames per species, the hat centred on the head) beside its five stats
as meters, below it in a window too narrow for both, its name (gold
when shiny) and personality, its level with an experience meter, and
what it said last on a band of its own (`harness-pet-speech-face`,
the action between asterisks in `harness-pet-action-face`), then the
two before it and a footer saying whether and through which model it
speaks and, when `harness-pet-overrides` sets any, which attributes are
set by hand.  Prose is filled to the window and drawn again when its width
changes.  The header line has [Pet] (`p`, `SPC`), [Rename] (`r`),
[Mute]/[Unmute] (`m`), [Release] (`R`, asks first) and [Turn off]
(`O`), or [Hatch] and [Turn off], and `g`, `q`; `s` spins the pet
(`harness-ui-pet-spin`, "Spin it" in the harness menu behind `.`; a 3D
turn, below), with no segment of its own.  Turned off (the VIEW's
`:enabled` false), the buffer shows the pet asleep, its eyes shut, and
[Turn it on] (`O` too); both set `harness-pet-enabled` through
`_harness/config/set` with the global scope, as the settings page does.

The art is plain strings, no image files.  `harness-ui-pet--sprites`
gives each species three frames of five lines, `{E}` standing for the
eyes and the first line blank, for the hat to take; the FRAME of
`harness-ui-pet-art` is taken modulo the number of them.  Frame 0 is
the creature at rest, 1 and 2 the others it moves between
(`harness-ui-pet--fidget` is the order it goes through them as it
speaks), and a frame may draw something above the head where the hat
goes, a "z z".  `harness-ui-pet--heads` is the column a species's head
is centred on, for its hat; `harness-ui-pet--faces` its face on one
line.  An eye or a face character the font cannot draw is an ASCII one
instead (`harness-ui-pet--eye-fallbacks`,
`harness-ui-pet--face-fallbacks`), so the lines keep their columns.

A spin is a real 3D turn, not text: a low-poly model of the creature,
its hat on its head, turns once about its vertical axis and is drawn at
run time as SVG images.  Two files of lisp/ui do it, and each loads as a
module of its own, as every file there does: `harness-ui-pet-3d`, the
renderer, and `harness-ui-pet-models`, the data, where nothing runs.
They need nothing of the harness UI (the renderer only `cl-lib` and
`subr-x`), and the requires go one way: `harness-ui-pet`, then
`harness-ui-pet-3d`, then `harness-ui-pet-models`.

`harness-ui-pet-models` has a model for each of the 18 species: an alist
from a species (a symbol, as `harness-ui-pet--sprites` names it) to a
plist.  `:palette` is the model's own colours, (NAME . "#rrggbb"), to
which every model adds `eye`, `shine` and `blush`
(`harness-ui-pet-3d-shared-colors`).  `:head` is (X Y Z RADIUS): the top
of the head, where a hat sits, and the head's radius, by which a hat is
scaled.  `:start` is the degrees the model is turned at rest, 0 facing
the viewer, -90 the viewer's left and 90 the right, so that it faces as
the species's text art does: the duck, the snail and the turtle -90, the
goose 90, the rest 0.  `:parts` is what it is made of.  The units are
the model's own, the renderer fits it to its box: the feet on y = 0, +y
up, the creature facing +z, toward the viewer at angle 0, and +x the
viewer's right.  A part is (KIND KEY VALUE...), and every kind is a
closed mesh with outward normals: `ball`, an ellipsoid (`:size` R or
(RX RY RZ), `:half` for the half above its centre, closed by a flat
disk, `:sides` the segments around), `box` (`:size` its half extents),
`tube`, a frustum along y (`:radius` below, `:top` above, 0 for a cone,
`:height`, `:sides`) and `ring`, a torus around y (`:radius` to the
middle of its tube, `:thickness` the tube's own radius, `:sides`).
Every kind takes `:at`, its centre; `:turn`, degrees about x, then y,
then z, about that centre; `:color`, a palette key, a shared colour's
name or a literal "#rrggbb"; `:mirror`, which adds a copy across x = 0
with its turn mirrored to match; `:detail`, for a small feature, an eye,
a nostril, a spot, which shows over what it sits on and hides nothing;
and `:flat`, for a part that is not shaded, the shine in an eye or a
blush.  The hats are `harness-ui-pet-hat-models`, an alist from a hat's
name, one of those of `harness-ui-pet--hats` (`crown`, `tophat`,
`propeller`, `halo`, `wizard`, `beanie` and `tinyduck`), to a plist with
its `:parts`, in units of the head's radius and around the model's
`:head` point as the origin: the renderer scales a hat by that radius and
moves it there, so each sits on any head.  A species or a hat is a
symbol or a string, as the pet's view has them; no hat, or one not
known, draws none.

`harness-ui-pet-3d` turns a model into a picture.  A model and hat are
built into a mesh once (`harness-ui-pet-3d--mesh-of`, kept by model in
`harness-ui-pet-3d--meshes`): each part becomes flat polygons with
outward normals, turned and placed, with its `:mirror` copy and the
hat's parts, scaled and moved to `:head`, beside them.  A face with
every corner inside the volume of another part (a ball, half ball, box
or tube, not a ring nor a detail) is left out, since it can never be
seen; one only partly inside stays, or a hole would open along the seam
where two parts meet.  What a frame runs is only the transform for its
angle: the model turns about y by its `:start` plus the angle, and the
camera looks down on it `harness-ui-pet-3d--tilt` (14) degrees, with no
perspective.  Faces that look away are dropped.  The rest are shaded
flat by a light from the upper left front (`harness-ui-pet-3d--light`):
a face's colour is multiplied by 0.58 + 0.47 N.L, N its normal and L the
light's direction, N.L never below 0, at most 1.05 in all, each channel
at most 255, or by 1 for a `:flat` part.

The order they are drawn in is that of a BSP tree, built with the mesh
(`harness-ui-pet-3d--order-tree`), not a sort: sorted by the depth of
their middles, faces went wrong wherever two parts run into each other,
as at every neck, leg and tail, the body showing in front of the head it
is behind.  Each node of the tree is the plane of a face; the faces in
front of the plane, on the side its normal points to, and those behind
it are each a tree of their own, and a face that crosses the plane is
cut in two along it (`harness-ui-pet-3d--cut`), the new corners added to
the mesh's points.  A face behind a plane cannot hide one in front of it
from a viewer in front of it, and the view has no perspective, so which
side of a plane the viewer is on is the sign of N.E, E the way to the
viewer in the model's space: the tree serves every angle, and a view
walks it back to front, at each node the far side, the faces in the
plane, then the near side (`harness-ui-pet-3d--draw-order`).  No face is
then drawn before one that hides it.  To keep the cuts few, a node takes
the plane, of `harness-ui-pet-3d--split-tries` (8) faces it tries spread
over those left, that runs through parts with the fewest faces, a part
counting as the ball it lies in; the rest of a convex part (a ball, a
box, a tube) lies behind each of its own planes, and a part whose ball is
wholly on one side of a plane is all on that side, so only the parts a
plane runs through are looked at face by face.  The faces of a species
and its hat, its details aside, come to 150 to 2,300 polygons so, the
tree built in 5 to 50 milliseconds.

The `:detail` faces are not in the tree.  For each view, those that look
at the viewer go down it as if `harness-ui-pet-3d--detail-bias` (0.06
units) nearer the viewer, which is each plane taken that much further
from it, and does not move them on the screen; they are cut where they
cross a plane, stay where they land, in a side of a node that has no
node, and are drawn at that point of the walk, part after part in the
order the model names them.  So an eye sunk a little into a head shows
whole, as it would standing out of it by that much, and a spot on a
plate thicker than that never shows through it from behind.

`harness-ui-pet-3d-svg MODEL HAT ANGLE WIDTH HEIGHT` writes that as an
SVG document, WIDTH by HEIGHT pixels, on a transparent background: one
`<polygon>` a face, or a piece of one that was cut, filled with its
shaded colour and stroked in the same colour, 0.6 px wide with round
joins, so that no seams show between neighbours, the coordinates rounded
to a tenth of a pixel and the string built directly.  MODEL is a species
or a plist, HAT a hat's name or nil, and ANGLE the degrees added to the
model's `:start`.

The fit is that of a whole turn, the hat included, and the same at every
angle, so the model never grows, shrinks or slides as it turns.  The
scale is the tighter of two: across, the greatest distance of any vertex
from the vertical axis, the radius of the bounding cylinder of the turn;
and down, the least and the greatest height any vertex reaches on the
screen as it turns.  The model is centred across, its lowest point
`harness-ui-pet-3d--margin` (4%) of the height above the bottom, and
fills `harness-ui-pet-3d--fill` (92%) of the box, across or down.

`harness-ui-pet-3d-frame SPECIES HAT STEP WIDTH HEIGHT` is step STEP of
a turn as an image.  A turn is `harness-ui-pet-3d-count` (24) steps and
step K is the SVG of K x 360 / 24 degrees, through `create-image` with
`:ascent 'center` and `:scale 1`.  Images are kept by their model, hat,
step and size (`harness-ui-pet-3d--frames`), the table emptied once it
holds more than 256 (`harness-ui-pet-3d-clear` empties it and the
meshes), so a turn is drawn once and shown from then on: a mesh takes a
few tens of milliseconds the first time, a picture a few.  It is nil for
a species with no model and where this Emacs cannot show an SVG.  A
step shows for `harness-ui-pet-3d-tick` (0.09) seconds.

For a look without images there is a text map.
`harness-ui-pet-3d-preview MODEL HAT ANGLE COLS ROWS` draws the same
picture on cells twice as tall as wide, as a terminal's are, each the
letter of the colour of the polygon drawn last over its middle, or `.`
where there is none, with a legend line under the map saying which
letter is which colour and how many cells it has (with SHADE, a digit
from 0 to 9 for the light instead).  A polygon holds the points it winds
round, SVG's nonzero rule (`harness-ui-pet-3d--point-in-polygon-p`), so
the map shows what the SVG does even where rounding turned a corner of a
cut polygon back on itself.  `harness-ui-pet-3d-print-previews` prints
such maps from a batch Emacs, `harness-ui-pet-3d-stats` counts a model's
faces before and after the hidden ones go and the polygons they are cut
into, and
`harness-ui-pet-3d-problems` lists what is wrong with a model or a hat by
the numbers: a part of a kind or with a key it does not know, a colour
that is not known or is nearly black but the eyes', a `:head` that is not
four numbers, more than `harness-ui-pet-3d--max-faces` (600) faces and a
part that floats free of the rest.

The places besides, those `harness-ui-pet-places` names (`chat`,
`board` and `sessions` by default), show only while the pet is on and
hatched, and their hooks are set only then (`harness-ui-pet--wire`):

- `chat`: its figure in the bottom right corner of a chat, first in the
  chat's tail (`harness-chat-top-functions`, `harness-ui-pet--panel`), so
  it stands on whatever comes first below the transcript: the activity
  line while a turn runs, a request waiting for the user, the queue, the
  todo list or a panel (`harness-chat-panel-functions`), and on the
  compose box when none shows, as Claude Code's companion sits beside its
  prompt; not in BTW chats.  The activity line goes under it, its overlay
  where the text marked `harness-chat-top` ends
  (`harness-chat--activity-position`).  The figure was among the chat's
  panels once, and `harness-ui-pet--wire` still takes it off that hook, so
  a reload forgets that.  The whole creature (`harness-ui-pet--sprite`,
  the art's blank lines and margin trimmed, its lines padded to one
  width) is as many lines as it is tall, the chat having no lines of its
  own for it to share, its name beside its eyes in bold, in its rarity's
  colour (gold when shiny).  What it last said about the session
  replaces the name: a
  speech bubble on its left (`harness-ui-pet--bubble`, box-drawing
  characters when the font has them all, else ASCII), its words centred
  on the creature's eyes.  The bubble is joined to the creature (`├─`) at
  the line of words nearest the eyes (`harness-ui-pet--rows`).  The words
  take `harness-ui-pet--bubble-width` columns (30) a line, more up to
  `harness-ui-pet--bubble-max` (60) so the bubble is no taller than the
  creature, and at most `harness-ui-pet--bubble-lines` (4) lines, the
  last cut short with an ellipsis.  Hovering over the bubble says all the
  words, when and about which session, on one line.  Each row is
  right-aligned by a space whose `:align-to` is `(- right (PIXELS))`,
  PIXELS the row as drawn and a column for its newline.  So the figure
  ends a column short of the window's edge whatever the font or text
  scale, its newline taking that column (`harness-ui-pet--pixels`:
  measured in a window showing the buffer, without selecting it, so a
  timer run with a daemon's terminal frame selected measures right and
  point stays where the chat draws).  Every row, its newline too, has
  `harness-pet-figure-face` (fixed pitch) and `default` under its own
  faces, so it stands on the window's own background, whatever a chat
  puts behind its panels.  How it fits is `harness-ui-pet--fit`, from the
  narrowest and shortest of the windows showing the buffer.  A window
  narrower than `harness-ui-pet--whole-columns` (40) or shorter than
  `harness-ui-pet--min-lines` (20) gets the pet's face on one line
  instead (`harness-ui-pet--face-row`), with its name, or the first of
  its words in quotes (`harness-ui-pet--quip-width`, 28 columns, cut at
  a space), as Claude Code's narrow terminals do.  So does every window
  with `harness-ui-pet-figure` set to `face`.  Only a window too narrow
  for even the face goes without.  The words are what the pet last said
  about that session's work (scope `session`, `harness-ui-pet--saying-for`):
  never its recap of the session, which is an overview's, nor what it
  said about itself.  They show until the session's next
  `agent/turn-started` or for `harness-ui-pet-saying-lifetime` seconds
  (60; nil, until it says something else there), and not while the pet
  is muted.  Hovering over the creature names it, a click shows the
  buffer.
- `board`: the same figure in the task board's bottom right corner, from
  `harness-ui-tasks-corner-functions` (`harness-ui-pet--board-corner`),
  with what it said last about itself (scope `pet`) or its recap of a
  session the board lists (scope `overview`; the sessions of its tasks
  not archived, `harness-ui-pet--overview-sessions`), never what it said
  about a session's work (`harness-ui-pet--latest-saying`).  A saying
  from before scopes is its session's when it names one, else the pet's
  own (`harness-ui-pet--scope`).  Its bottom rows end the first
  lines above the compose box, those that leave it room (the label, then
  the settings), as many as save lines.  So the creature takes only the
  lines it is taller than they are, and its bubble goes beside its upper
  rows.  The rows on the board's lines have `harness-pet-figure-face`
  alone, so the band of a box that messages a session shows through.
- `sessions`: the same figure under the session list's last row, from
  `harness-ui-sessions-footer-functions`
  (`harness-ui-pet--sessions-footer`), with what it said last about
  itself or its recap of a session on the list, as on the board
  (`harness-ui-pet--latest-saying`, place `sessions`, the ids of the
  list's rows).  A blank line comes first, so it stands apart from the
  rows; then the creature, right-aligned, as many lines as it is tall
  with its bubble beside it, the list having no lines of its own to
  share either, on `harness-pet-figure-face` and `default` as in a chat.
  The list is printed again whenever sessions change and, while any
  streams, at most every half second, and each print asks for the figure,
  whose lines cost a measurement in pixels.  So `harness-ui-pet--draw`
  keeps the lines it drew (`harness-ui-pet--lines-kept`, buffer-local)
  with the spec and faces they were drawn for, and returns the same ones
  while those are equal.  A narrow or short window gets the face, as
  anywhere.
  It is no session's: RET and the row commands find none on its lines.
- `chat-header`: its face on one line (`harness-ui-pet-face SPECIES EYE
  BLINK`, after Claude Code's, `(·>` for a duck) in its rarity's colour,
  from `harness-chat-header-end-functions` at priority 2, so it goes
  before anything else in a narrow window.  While the session runs it
  blinks once in fifteen half seconds, drawn by the chat's own spinner
  redraws, so it needs no timer.  It names the pet on hover, and a
  click shows the buffer.
- `board-header`: its face and name in the board's header line, from
  `harness-ui-tasks-header-functions` as `(TEXT 15 FACE)`, so the name
  goes first, then the face.

They draw from the pet as this Emacs last heard of it
(`harness-ui-pet--current`), asked for as the module starts and on every
connect, then followed through `pet/changed`, and `config/changed` of a
`harness-pet-` option.  Each chat, board and session list notes what its
figure shows (`harness-ui-pet--panel-shown`: the look, the words, the
fit and the pixels of a column), and `harness-ui-pet--sync-panels` draws
it again only where that would change -- a chat's tail through
`harness-compose-redraw-function` once the chat has drawn its compose
box, a board's tail lines through `harness-ui-tasks-redraw-tail-lines`,
the session list through `harness-ui-sessions-redraw` -- after
`pet/changed` (what it says comes with one), `agent/turn-started` and a
change of places, and, 0.1 s after things settle, as windows change size
(`window-size-change-functions`, while it sits in chats or under the
list; a board fits its tail itself), buffer
(`window-buffer-change-functions`) or text scale (`text-scale-mode-hook`).
A buffer no window shows is drawn again only when what its figure shows
changes, not for want of room: the window that shows it next fits it.
No periodic timer draws it; only its moving, below, and the fading of
its words have timers.  Words leave a bubble when they grow older than
`harness-ui-pet-saying-lifetime`: one timer (`harness-ui-pet--fade-timer`),
armed after every `harness-ui-pet--sync-panels` for the oldest saying a
figure shows (`harness-ui-pet--expiry`), runs it again then
(`harness-ui-pet--fade`).  None waits while no bubble shows a saying.
Only the bubble forgets it: the buffer and the pet's record keep it.

This Emacs tells the harness where the pet is on screen
(`_harness/pet/watch`, client `HOST:PID`) whenever that changes
(`harness-ui-pet--seen`): a plist of `:self`, t while the buffer is on
screen, or a board while the pet sits on boards, or the session list
while it sits there; `:sessions`, with `chat`, the ids of the sessions
whose chats are on screen, so the pet speaks about those sessions'
work only; and `:overview`, the ids of the sessions those boards and
lists list, whose recaps it says there.  Nil, so nowhere, while no frame
of this Emacs is attended: visible and focused, or not known to be
unfocused, a daemon's initial frame aside (`harness-ui-pet--attended-p`,
from `frame-focus-state`).  It is sent from
`window-buffer-change-functions` while the buffer lives or the pet sits
in chats, on boards or under the list, as the buffer is killed, after
every connect, and 0.3 s after a frame gains or loses focus
(`after-focus-change-function`, in the same places) or a board or list
comes to list other sessions as its figure is drawn
(`harness-ui-pet--note-listed`; `harness-ui-pet--watch-soon` tells a
burst once).

A figure has frames besides the creature at rest, all drawn to its
geometry, so one can take another's place on screen.  FRAME, of
`harness-ui-pet--figure-art` and `harness-ui-pet--sprite`, is nil or 0
for the creature at rest, 1 or 2 for its other frames and `blink` for it
at rest with its eyes shut.  Every frame has the same lines (the hat
line is the rest frame's, so what a frame draws above the head, a
"z z", shows on the card only), the same margin (the smallest any frame
has) and, padded, the same width (the widest line of any frame,
`harness-ui-pet--figure-width`).  Each row of the creature is marked
with its number from the top, 0, as the text property
`harness-ui-pet-row`; the face on one line is the row `face`
(`harness-ui-pet--face-row`).  A frame is drawn once for a look, an eye
as drawn and a frame, and kept (`harness-ui-pet--sprite-cache`, emptied
past 64 entries); its rows are shared, so do not change them.  What a
figure shows (`harness-ui-pet--show-frame`) may also be `(spin . K)`, the
Kth step of the spin's turn, K from 0 to `harness-ui-pet-3d-count` minus
1 (`harness-ui-pet--spin-frame-p`): that is a picture, not lines of
art, and the sprite has none of it.

Animations in the pet's buffer -- the egg wobbling then cracking and
sparkles as it hatches, hearts as it is petted, a fidget as it speaks
(after the sparkles, when its first words come while it hatches), and a
spin at `s` (`harness-ui-pet--spin-turns` (2) turns of
`harness-ui-pet-3d-count` pictures each; it too waits for the hatching to
end) -- are a few frames each, `harness-ui-pet--next` the frame after
one, on one timer (`harness-ui-pet--timer`) that stops with the last
frame or as soon as the buffer is off screen; each frame draws the card
again.  A frame lasts `harness-ui-pet--pace` seconds:
`harness-ui-pet--tick` (0.18) for the others, `harness-ui-pet-3d-tick`
(0.09) for the spin, the timer made again at the pace of the animation
that plays next.  The card's spin puts the picture of its step, cut to
the card's font for the creature (`harness-pet-art-face`), over the
creature's lines (`harness-ui-pet--card-turn`,
`harness-ui-pet--card-line` and, for the slices, below): each line from
the first the creature is on to the last shows its band of the picture
instead of its text, after the blank columns all the lines start with,
which stay as they are, so the card keeps its layout and the stats
beside it stay put.  Where the card cannot show a turn, `s` does not
start one (below).

The figures in chats, on boards and under the list move too, without
being drawn again (`harness-ui-pet--play`).  A beat is a list of frames,
one shown a tick (`harness-ui-pet--beat-frames`), each ending at rest,
frame 0: `blink` (the eyes shut for a tick), `twice`, `wiggle` (frame 1
and back, twice), `fidget` (`harness-ui-pet--fidget`; `pet/said` plays it
wherever a figure is on screen, as it does on the card) and `spin` (one
turn: the steps `(spin . 0)` to `(spin . 23)`, `harness-ui-pet-3d-count`
of them, then the creature at rest; `s` plays it too).  Idle, the
figures wait a random 6 to 14 seconds (`harness-ui-pet--idle-gap`) on
one one-shot timer (`harness-ui-pet--idle-timer`), then play a beat
picked by weight (`harness-ui-pet--idle-beats`: blink 55, twice 12,
wiggle 25, spin 2).  The spin is the rare one: the weights add up to 94
and a wait is 10 seconds on average, so a spin comes one beat in 47,
about every eight minutes while a figure on screen can show it.  Where
no figure on screen is whole, a face on one line, there is only a blink
or two (`harness-ui-pet--pick-beat`), as a face moves for a blink only.
A beat plays on a repeating timer (`harness-ui-pet--beat-timer`, every
`harness-ui-pet--pace` seconds: `harness-ui-pet--tick`, or
`harness-ui-pet-3d-tick` for a spin) that exists only while it plays (a
spin, the longest, is 25 ticks, a little over two seconds), so outside a
beat only the one-shot timer exists.

Showing a frame swaps the `display` property of each run of text marked
`harness-ui-pet-row` (`harness-ui-pet--show-frame`,
`harness-ui-pet--show-here`) for the last columns, as many as the run is
wide, of the same row of the frame; the display string has the run's
other properties, its colour, hovering and click, and at rest the
property goes.  The host buffer's text is never edited or drawn again,
and this is done in `with-silent-modifications`, so
`buffer-chars-modified-tick`, the undo list, the modified flag and point
stay as they were, and typing and scrolling are no slower; a frame is a
few property changes and the redisplay of a few lines.  The runs are
found from the buffer's end, as far as the figure's top row, and kept
until text is inserted or deleted (`harness-ui-pet--runs`, by
`buffer-chars-modified-tick`: a change of properties leaves them be).

A step of the spin is shown as a picture, in slices over those runs.
The image (`harness-ui-pet--turn-picture`: `harness-ui-pet-3d-frame` of
the pet's species and hat at that step) covers the whole creature: the
figure's width in pixels, the columns of its rows (they are padded to
one width) times the pixels a column takes, by as many rows as the
creature has, each as high as a line of the figure's font.  That is
`harness-ui-pet--cell`: the ascent and the descent of the font the
figure's faces draw, measured in the window that shows the buffer, so a
scaled text scales it, which is what a line takes, the figure being fixed
pitch.  Each run gets as its `display` the band of the picture its row is,
`((slice X Y W H) IMAGE)` (`harness-ui-pet--slice`): row N is the band
that starts N lines down, one line high, and as the image has `:ascent
'center` the slice covers its line exactly, with no gap between rows and
no line taller than it was.  A run shorter than the figure is wide is
the creature's part of the row a speech bubble's joint runs along
(`harness-ui-pet--rows`: the joint takes the blanks the creature has at
the start of that row, and its characters are marked
`harness-ui-pet-joint`).  The model is not bound to those blanks, so
while a picture shows, its band also covers the joint's last columns, as
many as the run is short of the figure's width
(`harness-ui-pet--reach`).  The whole band shows, no pixel of the model
is hidden under the joint's glyphs, and the joint ends a few columns
before the model.  No text is edited, and at rest the `display` goes as
it does for the other frames, so those columns show the joint again.  The face on one line never turns, and a buffer that
cannot show the picture shows the creature at rest for the step.

The spin is left out where it cannot show.  `harness-ui-pet--spin-block
SPECIES` says why, for the buffer it is asked in: `frame` when the
buffer's frame is not a graphical one, `svg` when it is but this Emacs
shows no SVG images (together `harness-ui-pet--graphic-p`:
`display-graphic-p` of the frame that shows the buffer, else the
selected one, and `image-type-available-p` of `svg`), `model` when
`harness-ui-pet-3d-model` has none for the species, and nil when the
spin can show.  A figure can show it (`harness-ui-pet--spinner-p`) when
it is the whole creature (`harness-ui-pet--whole-p`) and nothing blocks
it.  `harness-ui-pet--pick-beat` leaves `spin` out of the beats of an
idle moment unless some figure on screen can, so on a terminal the
pet only blinks, wiggles and fidgets, and `harness-ui-pet--play` of a
`spin` does nothing unless one can either.  `s` asks the same of the
pet's own buffer (`harness-ui-pet--spin-refused`), and when it cannot,
says why in the echo area with the pet's name, "Mochi spins only in a
graphical frame", "... only where Emacs shows SVG images" or "... has no
3D model to spin yet", and does nothing.

A figure moves while a window of a visible frame shows it
(`harness-ui-pet--figure-buffers`); the buffers a frame moved are put
back at rest as the beat ends, on screen or not
(`harness-ui-pet--moved`).  Nothing runs while nothing moves:
`harness-ui-pet--animating-p` wants `harness-ui-pet-animations`, the pet
on and hatched, and a figure on screen; `harness-ui-pet--arm` waits for
the next idle beat while it holds, and otherwise stands still
(`harness-ui-pet--still`: both timers cancelled, the beat forgotten, the
figures at rest).  It is asked after anything that may change which
figures are on screen -- `harness-ui-pet--sync-panels`, the window hook
`harness-ui-pet--on-window-buffer`, and the setter of
`harness-ui-pet-animations`, which stops everything at once when set to
nil -- and a timer that finds otherwise stops everything itself.  One
that signals stops the figures first (`harness-ui-pet--guarding`), so a
repeating timer does not signal on every tick.  A figure drawn anew is
at rest.

Cost display: whatever shows what a session cost goes through
`harness-ui-format-spend`.  That is a price when calls are billed per
token, and the plan's name (`Max`) when a subscription pays, after any
extra usage billed (`$0.40+Max`); the tooltip explains it and gives
the value at API prices.  The chat header adds the plan's 5-hour and
weekly windows (`Max · 5h 9% · 7d 57%`, coloured as they fill)
and opens the usage dashboard.  The dashboard's Plan section shows
every quota window with its reset time and the plan's extra usage,
and its chart stacks what a plan covered on top of the billed cost.
The UI keeps each provider's QUOTA from `provider/quota` and
`provider/quota-updated` (`harness-ui-quota`).  The task board's header
shows its tasks the same way: `harness-ui-sessions-total` takes their
sessions as one (their usage summed, the billing and plan of the one
updated last, the provider of the new-task model), which
`harness-ui-format-spend` formats with the plan's windows, saying
"These tasks" in its tooltip; `harness-ui-spend-segment` makes the
chat's and the board's text a header segment, its `%` escaped, that
opens the dashboard.  The board adds the fullest budget of the
project from `usage/project-budgets`: `harness-ui-format-budgets`
reads `budget 62%`, coloured as a quota window, and describes each
budget in its one-line tooltip (`harness-ui-describe-budget`).  In a
narrow window the board's segment (`harness-ui-tasks--spend-segment`)
outlasts most buttons, its budget making room first.
The dashboard's budget lines are made from the same pieces
(`harness-ui-budget-label`, `harness-ui-budget-spent`,
`harness-ui-budget-pace`).  Under the Plan section
the dashboard's Fallback section edits `harness-fallback-models` (from
`fallback/status`, saved with `config/set`, global): the entries in
order, each with whether it is available, out of quota until when, out
of money, or not set up, and [try now] (`fallback/clear`), [up],
[down] and [remove]; [add] (`f`) offers each provider ("model of
similar ability") and each model.  `M-<up>`/`M-<down>` move the entry
at point, `d` removes it (or the budget at point), `c` clears its mark.
It follows `fallback/changed` and `config/changed`.

Cost comparison (`harness-ui-cost-compare`, module `ui-cost-compare`):
the dashboard's `C` or `[compare]` (`harness-cost-compare`) opens
`*harness cost comparison*`, which asks `usage/cost-compare` (module
`cost-compare`) what the tokens the dashboard recorded -- its period's,
or one session's -- would have cost at each priced model of the
catalogue.  The answer re-prices the recorded token counts with the
rates the catalogue carries (a model's `:pricing', or the plist its
`:pricing-fn' answers for the clock, as DeepSeek does) through
`usage/price', and compares each result with the recorded `:list-cost',
the tokens' value at API prices, since a call a plan covered was billed
nothing.  Tokens a model prices no cache read for, or prices a cache
write below its input for, are reported and priced as input, which is
what that model would have billed them; a model the catalogue does not
price reads unknown, never zero.  The rows are cheapest first, marked
where they are the model the usage ran on.  It is read-only: no row,
cost or budget changes.

The Budgets section lists the harness's budgets, the Budget setting's
and the sessions' own (`usage/budget-status` on "settings" and
"session:SID").  A budget's line has [delete]
[baseline] [plan] right after its name, padded to one width so the
meters line up: the dashboard does not wrap lines, and buttons at the
end of a budget's long line were out of sight.  [delete] or `d` deletes
the budget with `usage/remove-budget`, or a session's own one with
`session/update :budget nil`, and says the Budget setting's is changed
with `M-x harness-settings`; `harness-delete-budget` (`C-c h B`,
"Delete budget" in the harness menu) does it from anywhere, the budget
read by name (on a budget's line, that one is the default).  A hard
budget's refusal says it is deleted there, or the setting's, where it
is changed.

Session list (`harness-ui-sessions`, `*harness sessions*`, a
`tabulated-list-mode` buffer): tree indentation for children, filter and
sort by any column, scoped to the current project, its git worktrees and
so its tasks' sessions included (each session's root is resolved to its
main checkout once, with `harness-files-owning-checkout`), or, with `a`,
to every project.  A task's session is of kind task and goes by its
task's title, as on the board, until the model names it after its first
turn: the list loads the tasks with `_harness/task/list` and follows
`task/changed` and `task/deleted`.  Its rows are printed by `harness-ui-sessions--print-row`, each cell
ending in a space aligned to the next column's start whether it fills
its column or not, so a long name or a glyph wider than a cell never
shifts the rest of its row, and the figures -- Context, Output, Tok/s and
Cost, wide enough for `$0.0058+Max` -- are right-aligned.  SPC on a session pops out what it
waits on (a session that waits on nothing leaves SPC scrolling), its
status cell's tooltip says so (`harness-ui-sessions-requests`).

A module draws under the rows through `harness-ui-sessions-footer-functions`,
each function returning a string of whole lines, or nil, called whenever
the list is printed: the printer (`harness-ui-sessions--print-entry`)
inserts them after the last row of the print, whichever column the rows
are sorted by, and after the line saying what that session waits on, and
`harness-ui-sessions--print` where there is no row at all; they are no
session's, their lines carry no `tabulated-list-id`, so `RET` and the row
commands find none there, and a function that signals draws nothing; the
companion pet's figure sits there, and `harness-ui-sessions-redraw`
prints the list again, each window keeping its point on its session, when
what a function would draw changes.


Its columns are one spec (`harness-ui-sessions--columns`), from which
the header, the rows and the sorts are made: the status icon, which is
always there, then Name, Status, Kind, Model, Think, Mode, Priority,
Context, Output, Avg tok/s, Cost, Last msg and Project.  Think is the
session's `:thinking` as plain text, empty for a session on its model's
default, and sorts weakest level first.  Context and Output show each
session's token figures, which grow while it streams.  Avg tok/s is the
session's average output rate over its whole life
(`harness-ui-format-average-rate`, without the unit), never dimmed, with
the current rate named in its tooltip.  Last msg is how long ago the
session's `:last-message` came, else, for a record from before the
session kept that, its `:updated`, which the tooltip says.  Priority
shows each session's arrow (up for high, down for low, nothing at the
default medium, as a task's card and a chat's header line do), and it is
a button: a click asks for that row's session's priority as the header's
arrow does.  Mode and Output are hidden by default
(`harness-ui-sessions-hidden-columns`); `C`
(`harness-ui-sessions-toggle-column`) shows or hides a column in that
list only, which then keeps a list of its own, and a sort by a column
that is no longer shown ends.  Project shows only when the list covers
every project.

Sessions are marked as files are in Dired.  The marks are session ids in
a table kept apart from the rows (`harness-ui-sessions--marked`), so a
redraw, `g`, the filters, a change of scope and the pause leave them as
they are, and a session the filters hide stays marked; the table drops
the ids of sessions the session cache no longer has at each refresh.
`m` marks the session at point and moves to the next row (a numeric
argument marks that many, a negative one the rows above), `u` unmarks it,
`DEL` moves up and unmarks the row there, `U` unmarks every session, the
hidden ones too, and `t` inverts the marks of the rows listed.  A mark
shows as a `*` (`harness-ui-sessions-mark-face`) in place of the row's
padding space, changed in place with `tabulated-list-put-tag` and no
redraw, so a paused list shows it; the mode line counts the marked
sessions, hidden ones included.  The commands that act on sessions ask
`harness-ui-sessions--targets` which: the marked sessions, the ones the
list shows in the order of its rows, then the hidden ones newest first,
else the session at point.  `d` deletes them after one question that
counts the marked sessions and says how many the list does not show
(`_harness/session/delete` for each), `k` cancels the turns of those
that are running or blocked, `x` deactivates them
(`_harness/session/deactivate`), `M-t` makes them tasks
(`_harness/task/adopt`, skipping a session that is a task already),
`+` and `-` raise and lower each one's priority a level
(`harness-priority-shift-session`) and `p` sets it, asking for the level
once (one `_harness/priority/set-all` with their ids for several; a
prefix argument on `+` or `-` asks too).  `d`, `x` and `M-t` send their
requests together and finish once, when the last is answered: they
unmark the sessions that went through, leave the mark on one they
skipped (a task already, for `M-t`) or that failed, redraw the list once
and say one message.  `k` cancels each turn at once, unmarks those
sessions and leaves the mark on one with no turn to cancel (an idle
session); `+`, `-` and `p` leave the marks, so several changes can be
given to the same sessions.  `f`, `r` and `M` act
on one session and refuse while any is marked
(`harness-ui-sessions--one-id`); `RET`, `o`, `SPC`, `y` and `n` are the
session at point's, marked or not.

The harness's setting commands (`harness-set-model`,
`harness-set-thinking`, `harness-set-permission-mode`,
`harness-toggle-non-interactive` and `harness-toggle-supervisor`: the
prefix keys `C-c h m`, `T`, `p`, `i` and `V`, and the menu's) ask the
buffer what they change through `harness-ui-setting-target-function`,
and the list answers with `harness-ui-sessions--setting-target`: the id
of the session at point when none is marked (nil off a row, so they ask
which), else `(VALUES SET-FN CONTEXT)`, the shape the task board's
new-task settings use.  VALUES holds the settings the marked sessions
agree on (`harness-ui-sessions--marked-values`: a setting they differ on
is left out, as if unset), which the commands offer as the current ones;
SET-FN is `harness-ui-sessions--set-marked`; CONTEXT says "for the 3
marked sessions".  SET-FN reads the marks in the list when it runs and
sends one request for the sessions: `_harness/session/set-all` with the
marked ids as the filter (`(:ids IDS)`), `_harness/supervisor/set-all`
for the supervisor mode, and for a model `_harness/handoff/check-all`,
then `_harness/session/set-all` when no conversation would be lost or,
when one would, `harness-ui-switch-function` asking once for all of them
how to hand them over (the answer `cancel` changes nothing) and
`_harness/handoff/switch-all` by the mode chosen.  Then, for the marked
sessions that work on a task, one `_harness/task/set-all` with the
setting and the tasks' ids as its filter (`(:ids TASK-IDS)`, tasks of
every project, none named by a project), so each task starts again with
it; the tasks in review, done or archived are skipped, as `task/set-all`
always does.  One message says how many sessions and tasks changed, and
a request that fails says why.  The marks stay.  The list binds none of
these commands to a key (its `m`, `T`, `p` and `i` are others), so its
menu group, which lists the keys the buffer has, does not list them; the
menu's own Session settings column, which lists all but supervisor mode
(its `V` sets every session's), does, and runs them here.

`T` lists only the sessions that work on a task, and their sub-agents,
forks and BTW conversations however deep
(`harness-ui-sessions-toggle-tasks-only`).  `I` shows the kinds the list
leaves out, by default `internal` (`harness-ui-sessions-hidden-kinds`,
`harness-ui-sessions-toggle-internal`).  With `b` (blocked), `i`
(inactive) and `/` (the filter) these are the list's filters, and its
mode line says which are on.  The mode line also holds a `[Pause]`
button, first, as a narrow mode line cuts its end, which `P` presses too
(`harness-ui-sessions-toggle-pause`): a paused list holds still, reading
`[Paused: resume]`.  The paths by which the list follows the harness --
session changes, output rates and growing token figures, the requests
sessions wait on, a reload of the UI, the tasks fetched after a
reconnect -- redraw through `harness-ui-sessions--redraw-live`, which
leaves a paused list as it is; a change or a growing figure schedules no
redraw for it, and pausing drops those already scheduled.  What the user
asks of the list (the filter, the scope, the toggles) and `g` redraw it
anyway, with what changed meanwhile, and resuming redraws it once.

In the fullscreen layout (`F`) the session beside the list is the one at
point, else the most recently updated one listed, where a BTW
conversation and a session of a hidden kind are passed over even when
the list shows them (`harness-ui-sessions--overview-session`).

Other buffers: settings page (`harness-ui-config`, above), sessions list
(above; it follows `task/changed' and
`task/deleted'),
conversation tree (`harness-ui-tree`: each row's properties, its
`mouse-face` among them, stop before its newline, so hovering highlights
that row alone), usage dashboard (`harness-ui-usage`,
svg charts via svg.el; by project, the rows of a project's git
worktrees, its tasks' and sub-agents', fold by their `:main` into one
line with their sum and count, folded until TAB, RET or a click unfolds
it, `w` or `[show worktrees]` every project, the main checkout's own
usage first, then each worktree's; a redraw keeps every window's start
and point lines), cost comparison (`harness-ui-cost-compare`:
`*harness cost comparison*`, the tokens the dashboard recorded
re-priced at every priced model of the catalogue, cheapest first, each
with the difference from their value at API prices, opened from the
dashboard's `C' or `[compare]', `g' refresh and `t' the period;
read-only), Insights report (`harness-ui-insights`:
`*harness insights*`, a read-only view with a placeholder until
`_harness/insights/compute` answers, then the totals, the written
summary (`_harness/insights/narrative`, asked for once the figures
are in), activity, usage (the dashboard's chart and meters), projects,
sessions, tools, permissions and tasks; its periods and their `:since`
are the dashboard's (`harness-ui-usage--since`), so its usage figures
are too; `t` the period, `p` the project, `n` the summary again, `g`
all again, RET a session or task line's session; a redraw keeps every
window's start and point lines), worktrees (`harness-ui-worktree`),
notifier
(`harness-ui-notify`: global mode-line segment with blocked and running
counts of the user's sessions (`harness-ui-user-sessions`, so no internal
session), idle ones too with `harness-ui-notify-show-idle`, clickable;
`harness-ui-notify-segment-functions` add segments of other modules
after its "harness", such as the version page's nag icon and the task
board's count of tasks ready for review, and keep it showing with no
session active), BTW side window (`harness-ui-btw`: a
new, empty
session listed under the session it is opened over but sharing nothing
with it or with other BTWs (`session/btw`), or, over a view that sets
`harness-ui-btw-start-function`, a new conversation the view starts, shown
in the session's own chat buffer with point in its compose box, so the
question is written and sent like any message; nothing is read in the
minibuffer.  The buffer is the full chat: its header line (model,
permission mode, non-interactive while it is, thinking, context, cost, [menu]),
keys and menu are a session's, `harness-ui-btw-minor-mode` only adding a BTW segment in
front of the header through `harness-chat-header-functions` (what it
is about, [close], [keep]) and `C-c C-k`/`C-c C-o` to close and keep
it; one over a session starts in that session's permission mode, and
every one on the BTW model (`harness-btw-model`: by default the cheap
tier of the provider of the model it would otherwise use) at the BTW
thinking level (`harness-btw-thinking`, fitted to the levels its model
offers: the nearest it has below it when it lacks the level, else its
weakest).  `harness-btw` takes a MODEL
(a `PROVIDER:NAME`, sent as `model` to `_harness/session/btw`, or to the
view's start function as its second argument, only when one is given)
for that BTW alone, and the symbol `choose` reads one from the
catalogue first (`harness-ui-choose-model`; an empty answer opens
nothing): a prefix argument does it, from `harness-btw`, the board's
`harness-ui-tasks-btw` and the tree's `harness-ui-tree-btw`.  The
first message names it `btw: ...`, unless it was named by hand.
Closing it returns there; a BTW nothing was asked in is deleted with
its buffer, once the harness confirms it holds no node of its own,
and an idle one is closed.  Keeping it makes it a normal session
window in that place, with nothing of the BTW left in its header),
popout (`harness-ui-popout`: one item of a session or task -- the request
it waits on, a task's report -- in a selected bottom side window fitted
to it; a KEY names the item and reusing it reuses the buffer, so state
the owner keeps there survives: whoever owns the item passes a TITLE and
a RENDER, and with `:compose' the shared compose box under the content,
whose C-c C-c gives the owner the text and attachments.  `q' closes it,
`g' draws it again, and C-g closes it once there is nothing else to
quit; the content is a panel of the box (`harness-compose-panel`
`popout`, the panels the content drew keeping their own names), so
`C-c . q` and `C-c . g` press those keys from the box, where they type;
`harness-ui-popout-at-point-functions' lets a view pop out the item
at point with one key), media
(`harness-ui-media`: inline images, audio record/playback with svg
meters, video posters that play the video, and the attachments a tool
result or a message carries; a compose chip's thumbnail comes through
`harness-ui-media-video-thumbnail`, which makes one in the background and
tells the chip when it is there), popouts (`harness-ui-popout`: one item of
a session or a task in a small selected bottom side window, fitted to
its content up to `harness-ui-popout-max-height` or the popout's own
`:max-height`, one buffer per KEY the owner picks; `q`/`g` on the
content under the owner's own keys, `C-c C-c` sends its optional shared
compose box, `C-g` closes it, and `harness-ui-popout-at-point` runs the
first `harness-ui-popout-at-point-functions` that knows the item at
point; a popout opened from another (`:parent`) takes that one's
window, says [back], and gives the window back when it closes, and
`harness-ui-popout-pixel-width`/`-pixel-height` size what it draws for
the window it shows, or will show, in; `harness-ui-popout-image` is
one image as large as the frame allows, `harness-ui-popout-image-max-height`
of it, scaled down to fit or up by `harness-ui-popout-image-max-scale`
at most, with Emacs's image keys and [Open externally]), the review of
a task (`harness-ui-review`: one banner, the board's Ready for
review -- its heading, the handed-in report in full and always
expanded, then [Verify] (`C-c C-v`), [Send back] (`C-c C-x`) and
[Review] -- shown above the compose box of the task's session, a chat
panel (`harness-chat-panel-functions`), and at the end of its report
popout (`harness-ui-report-panel-functions`); the merge queue of a
session whose sub-agents merge into it (`harness-ui-merge`, module
`ui-merge`: beside the todo list above the compose box, a line per
child marked queued, merging, in conflict, merged or failed with the
reason the queue gave, the live ones first and the last few finished
after them, drawn from `merge/view` over ACP -- fetched once per
session and again on every `merge/*` event of that queue, so the panel
follows the merges as they happen; a session with nothing merging and
nothing merged recently shows no panel); the running sub-agents of a
session (`harness-ui-children`, module `ui-children`: beside the merge
queue above the compose box, a line per sub-agent still running -- its
session link, how long its turn has gone on, and the text of the
activity line or, before its first activity arrives, its current todo
item, cut to the room the chat's narrowest window leaves so the line
never wraps and moves the box below it -- drawn from the session
cache, the `_harness/activity` updates that
`harness-ui-update-functions` bring for every session, which it keeps
per session, and the `agent/turn-started` and `agent/turn-ended`
events, so nothing asks a child anything; a seed conversation is left
out by its `:seed` marker, and a chat draws the panel at most once a
second, one timer per chat taking the updates of all its children, and
only when the panel's text differs from the one it drew last); the tool
slots held back by the machine's load (`harness-ui-tool-slots-load`,
module `ui-tool-slots-load`, the UI half of tool-slots-load: beside the
sub-agents above the compose box, one line on a background of its own,
"Tool slots limited to 5 of 18: system load 1.8x on this machine", in
every open chat for as long as the slots in force are under the
baseline and in none while the machine has them all -- the notes in the
transcript are the history, and stand wherever a stretch of changes
began, this is how it stands now; the tooltip is what the sessions were
told of the last change and when; the state is cached from
`tool-slots/status`, which the UI asks for when it connects, which
forgets what the last harness said, and after `harness/reloaded`, and
is kept by `tool-slots/changed`, so nothing polls, and a state that
reads like the one shown draws nothing; a change draws the tail of
every open chat once, a chat still loading drawing it with the rest;
the panel is decoration, so one that fails to draw leaves the tail as
it was); the session's box sends
as always and the harness takes any message the user sends the task's
session for the feedback that sends it back (`harness-tasks--on-message'), so
[Send back] only points at the box, while
`harness-ui-report-compose-functions` gives the report box's text to
`task/reject` as the feedback; `harness-ui-review-minor-mode` puts
those two keys over the buffer's own, only for as long as it shows; it
follows the task events of its session and draws again only when what
it shows changes, finding the chat buffer by session id with `equal`,
since an id from the harness process is a fresh string), the switch
banner of a session (`harness-ui-handoff`: the chat panel that asks how
to hand the conversation over when a lossy model switch needs it -- the
models, the reason, the risks and costs as labelled rows, and a button
and a key per way to hand over, falling back to the minibuffer question
when no chat buffer shows; see "Switching model or provider"), the
prompt cache warning of a session (`harness-ui-cache`: the chat panel
that says the cache lapsed and what the next message re-sends, drawn
by a timer at the moment it lapses, with buttons that compact the
conversation first; see "Chat buffer"), cache warming
(`harness-ui-cache-warm`: the flame and countdown in the chat's header
while the cache is kept warm, the user's activity reported to the
harness, `/warm`; see "Chat buffer"), the cold-cache question
(`harness-ui-cowboy`: the panel that asks what goes first when a
message meets a cold cache, through `harness-ui-pending-panel-functions`;
see "Chat buffer"), compacting by hand
(`harness-ui-compact`: `harness-compact`, `C-c h C` and "C" in the
menu, asks which kind with `read-multiple-choice`, the help buffer a
table of each kind's writer, cost and effect and what carrying on
costs, from `compaction/estimate`; the kinds are brief, summary,
transcript and fresh; refuses a session running a turn; registers
/compact, /compact KIND, in `harness-chat-commands`), and the
handed-in report (`harness-ui-report`: the summary as markdown and the
evidence -- images as wide as the popout and up to
`harness-ui-report-image-max-height` of the frame high, the popout
growing to `harness-ui-report-max-height` for them, a click or RET
showing one larger in an image popout whose [back] returns to the
report; videos and files through ui-media, code as a block, notes, and
a referenced tool call drawn as the call it links to, with [Open in
the session]; opened from the board's [Review] button and from the
banner, in a popout of its own, to which other modules add panels and a
box, which follows `task/changed` and closes once the review is decided
-- the task turns verified, or is sent back with a new round of
`:feedback` -- wherever that was done; the report of a task decided
before it opened stays).

The review of a task's changes is three parts that know each other one
way.  The library `change-review` (lisp/vendor/change-review, see
Vendored libraries) is what a review is, how it looks and how it is
kept: a change set with versions, threads of comments and the Emacs
views that draw them, and nothing of the harness.  The module
`patch-review` (see its contract) is the harness process's half: it
keeps a task's threads, takes the operations the user and the agent
make, and carries the drafts with the feedback.  The module
`ui-patch-review` (`harness-ui-patch-review`) is the adapter that gives
the library a task to review in this Emacs.  Nothing else names it or
the backend (`harness-ui-patch-review-is-known-only-to-its-halves`
checks; the review tools and the ACP lists of what a UI may call and
hear are the exceptions), and the module's shutdown takes it out again.

What the library holds (its README has the whole of it): a CHANGE SET --
here a task -- with VERSIONS, each a proposal of the change, named by
its source revision (for a task, the commit its branch ends at when the
agent hands the work in; for an emailed series, the message id of its
first mail), and THREADS, each open or closed.  Closed is the good
ending, normally the point made or the change made.  A thread holds
COMMENTS.  A comment records its thread and the comment it answers, its
author, its time, the source revision it was written against, its place
in the code if it has one (file, side, line, and the lines of the diff
above it, as a reply on a mailing list quotes them) and whether it is
still a draft.  The author is a user, with a name and an address; an
agent, with its session and the tool call that wrote the comment, the
link back to that point of the conversation; or a person of another
kind, a mail's sender.  Everything that changes a set is an OPERATION,
plain data performed by `change-review-apply`; an operation names what
it adds, so performing it twice changes nothing, and that is what lets a
UI keep its own copy of what the harness keeps.  What differs between
hosts is a generic function that a subtype of the set answers
(`change-review-dispatch`, `-save`, `-current-author`, `-own-author-p`,
`-follow-author`, `-visit`, `-placement`, `-origin`, `-send`,
`-file-text`, `-default-revision`); the adapter answers them for a task.

THE ONE DRAWING.  A thread is drawn in one place,
`change-review-ui-thread-string`, whichever view shows it: a header (a
mark, open ● or closed ✓, the thread's short id, where it is, how many
comments, open or closed -- and by whom and when) with buttons for what
can be done with it ([Reply] [Close] or [Reopen] [Diff]), then each
comment under a bar that runs the thread's length: its place in the
thread (`2/3`), its author (marked "you" or "agent"), the time (exact,
and relative), the revision it was written against, a "draft" mark, the
comment it answers when that is not the one above (`↳ re 1/3`), a `▸
where` button that shows where the comment was made, and for an agent's
comment `↗ conversation`, then the text.  The text is drawn by the kind
of set: as it was typed, its lines wrapped under the bar, for a plain one,
and as a markup does where the kind of set says its comments are one --
`change-review-ui-body-lines` gives the lines of a comment, as wide as
the room under the bar, with their faces, and
`change-review-ui-body-summary` its first words, one line, which name a
thread drawn collapsed or as a row.  No line of it is wider than
the width it is drawn to (by default the columns of the window that
shows the buffer, `change-review-ui-current-width`): a header that would
be says less in steps -- for a closed thread how long ago it was closed
for the date, and who closed it only if it was not the user; then who
alone; then neither; the count of comments; the buttons.  For a comment
the date for how long ago, the revision, the words of its links, the
time, the marks -- and is cut only when it has given everything up.  Under a line of a diff a thread
also folds (`:fold`): a closed thread is one line, `▸ ✓ 3f9a1c · 3 comments
· closed 2h ago  “Why eighteen?…”`, no wider than 100 columns and the first
words of what its root says rather than of what that quotes
(`change-review-ui--summary`); `TAB` or a click opens it to its conversation
(`▾`), and one that is taller than the window has room for
(`change-review-ui-max-thread-lines`) is cut with `… 8 more lines`, which
`TAB` or a click draws in full.  How a thread is folded is the set's:
`change-review-ui-thread-fold` reads it from a weak table, keyed by the
set and the thread's id with the status it had when it was folded, so a
view drawn again, another view and the Ediff of the next file keep it, and
a thread whose status changed is what its status makes it at first.  The
drawing notes which threads it cut (`change-review-ui--trimmed`): `TAB`
goes one line, conversation, all of it when it did, one line again.
`change-review-ui-thread-line`
is the same thread as one row of a list.  The report's rows, the threads
view (`change-review-open-threads`, which lists every thread by file,
filtered by status with f and F) and the threads under the lines of
Ediff's two versions and of the library's own diff view
(`change-review-open-diff`) all call them, and the keys on a thread are
the library's whichever view it is in: r replies, x closes it or opens
it, s sets a status, e edits a draft, k deletes one, o follows an
agent's comment to the point of its conversation, RET (TAB in the
threads view) shows where its comment was made -- the file and line, the
revision, the lines of the diff it was made on, the session and tool
call of an agent -- and d shows the thread in the diff view
(`change-review-visit`: the library's diff view; Ediff for a task), in
the newest version; D shows the code the comment at point was written
on, in the version it was written against (`change-review-visit` takes
a version, and a location).

WHERE A COMMENT WAS MADE (`change-review-origin`) is where it was made,
not where its thread is now.  The answer to a comment changes the code it
is about, so the lines under `▸ where` are the diff of the revision the
comment was written against, as it was then, and not the newest
version's, which would make a comment read as if it asked for what is
there already.  A comment made on a line keeps the diff around the line
(its location's excerpt) and that is shown; a reply, whose thread started
on another revision, and a thread an agent started on a line, which has
no excerpt, have the lines of their own revision, found by the generic
function: the library's method places the thread in the diff of the
version the comment was written against, when the set holds that
version's files, and else says whose lines it shows ("the lines are those
of v1, where the thread started").  The details lead to the code: a
`[Source @ v1]` button (the revision's name), and `[Source @ v2]` for the
newest version, or one `[Source]` for a comment written against it; D in
the threads view; RET or a click on a line of the diff, that line of the
source, on the side a removed line is on (`change-review-ui-follow-source`).

THE ADAPTER.  This module gives a task to the library as a change set of
its own subtype (`harness-ui-patch-review--set`):

- Its versions come from the harness (`patch-review/get`), which
  recorded one each time the task came to review; the files of a version
  are read here, from git, in the task's repository.
- The threads are the harness's.  What the user does is performed on
  the copy here at once and sent (`change-review-dispatch`, the method
  `patch-review/apply` over ACP); what the harness does -- an agent's
  comment, the drafts sent -- reaches this copy as the event
  `patch-review/changed` and is performed on it.  An operation done
  twice changes nothing, so the user's own come back harmlessly.
- The author of every comment typed here is the user
  (`change-review-own-author-p` is true of any user); an agent's author
  follows to its conversation (`change-review-follow-author` opens the
  session at the tool call).  A task's agent writes with the
  `review_comment` tool.
- Where a thread is now (`change-review-placement`) is worked out in
  git (`harness-ui-patch-review--place-threads`): the thread's line in
  the revision it was written against, carried through `git diff -U0` of
  that revision's file against the branch's -- the same line, moved, or
  changed.  A thread whose revision is no longer in the repository is
  placed by the lines it quotes, and one on a file the branch deleted is
  gone.  This needs nothing the review keeps, so it survives a restart.
- A comment is written against a commit, which every comment records by
  its sha: the commit the branch was read at for a comment made in Ediff
  (the one its excerpt is from), the commit the agent was at for the
  agent's (`review_comment`).  In an Ediff the commit is the one the
  Ediff shows (`change-review-default-revision`), so a reply made in the
  Ediff of an earlier commit is written against that commit.  The
  commit is the code the comment is about, and the branch has gone past
  it, so the review reads the branch at that commit when it is asked for
  the commit's code (`harness-ui-patch-review--snapshot`): once per
  commit, from the version's recorded merge base, the diff of the commit
  against it and the places of the threads in that (the same placement
  as above, for that commit instead of the tip).  The result is a
  SNAPSHOT, a copy of the review with the files and the places of that
  commit (its `snapshot` slot is the commit), kept in the review by the
  commit.  The `change-review-origin` method
  (`harness-ui-patch-review--set`) answers from the review itself when
  the commit is the branch's end, from the snapshot once it is read,
  with the note "reading the diff at 68726a2…" while git answers, and,
  for a commit the repository does not have, the lines the thread kept
  and the reason.  The views draw again when it is read
  (`change-review-ui-refresh`).
- `change-review-visit` compares the file in Ediff with the thread's line
  in sight -- as the branch is, or, given a version, as that commit had
  it: the snapshot's Ediff, the merge base against the file of that
  commit, whose control panel says "as it was at 68726a2".  An Ediff of
  a snapshot is looked at, not reviewed: no file of it is marked seen or
  approved, and a comment made in it is written against that commit.
  `change-review-send` goes to the feedback box.
- A comment is Markdown (`harness-ui-patch-review-markdown`, on): the
  user writes it in a buffer, an agent in its `review_comment` call, and
  both use emphasis, `code`, fenced blocks, lists, quotes, tables and
  links.  `change-review-ui-body-lines` renders it as the chat renders a
  message (`harness-ui-markdown-render-lines`: wrapped to the room under
  the bar, a list's hanging indent, a code block's margin and background,
  a quote's bar in the text, a table fitted to the width) and
  `change-review-ui-body-summary` gives the words a row, or a thread
  drawn collapsed, is named by without the markers
  (`harness-ui-markdown-summary`).  The line breaks of a comment stay, as
  they do in what the user types in the chat
  (`harness-ui-markdown-hard-breaks`).  Every view of a thread draws the
  text through them, the threads view and the threads under the lines of
  Ediff as much as the report's rows.  A link in a comment is followed
  by a click, in the threads view by RET too, and a link to a file is
  relative to where the task worked (`harness-ui-patch-review--link-directory`:
  its worktree, else the repository); in a row, or a thread drawn
  collapsed, a link is its label.  The threads are drawn to the width of
  the window that shows them, Ediff's two versions once Ediff has laid
  them out.  Editing a draft reads the Markdown as typed; the feedback
  the agent is sent quotes it as typed too.

The panel is on `harness-ui-report-panel-functions` at depth -10, before
the review banner, and returns the changes of a task in review that has
a branch, and nothing for any other task.  A task that left review can
still show its changes: `harness-ui-patch-review-open`, on C-c C-d in a
task's session or on a board card (`harness-ui-patch-review-mode`),
opens its report with a review whose `:show` is set, and the panel then
draws for a task no longer in review.  With a prefix argument it asks
which diff to show first (`--choose-diff-for`, the question d asks in the
report) and keeps the answer in the review.  The panel is drawn in the popout
buffer, so it knows the report it is in; a report opened anew, a popout
buffer it has not drawn in yet, reads the branch again.  Its rows carry
a keymap of their own as a text property, which the popout puts before
its own keys.

The changes show for a task whose project, else its worktree, is a local
directory, when the harness is not remote
(`harness-ui-connection-address`); else the panel says why.  Git runs in
the Emacs that shows the UI, with `GIT_OPTIONAL_LOCKS=0`, so that it
takes no lock the task's own git could trip on.  `git merge-base` of the
branch with the task's `:base` (HEAD when that is blank or gone) gives
the commit compared with; `git diff --raw -z -M --no-abbrev` and the
patch between the two give the files and their hunks, paired by path,
and `git status` in the worktree tells the panel to say when it has
changes not committed.

THE DIFF SHOWN.  The commits compared are the reviewer's choice
(`harness-ui-patch-review-select-diff`, on d and the buttons of the
`Diff` line under the heading): the branch against its merge base with
`:base`, which is where a report starts, the branch against where it was
at the last review, or revisions typed.  The choice is the review's
`selector` -- nil, `since-review` or the string typed -- kept as the
tree toggle is, so a report closed and opened again shows it; what is
drawn is the diff `shown-selector` names, the one read last.
`harness-ui-patch-review--read-branch` takes the selector and has it
resolved to two commits.  `--resolve-since` takes the newest version of
the review's set whose tip is not the branch's (`--last-review`; a
version's tip is the commit the work was handed in at), among those
before the branch's own when it has one; a task sent back whose branch did
not move was handed in again at the same commit, which the round the
harness recorded in the version's meta (`harness-patch-review--version-op`)
says against the rounds the task has, and then the diff is empty and the
report says nothing changed.  `--resolve-spec` reads a string as
`git diff` takes revisions (`--parse-spec`: A..B, A...B, A B or A; a
start left out is the branch it was made from, an end left out the
branch's tip), each resolved to a commit, A...B to the merge base.  The
whole change of the branch against its merge base is read all the same,
whichever the diff, as the version of the set (`--attach-files` gives the
version those files, so the library's own views have them) and as where
a thread on a file the diff shown does not change is placed
(`--place-threads` goes through `--unshown-files` after the files shown,
each with the commit its new side is at).  What is wrong is refused
before the report changes -- no revision, three, one that starts with a
dash, a review before this one when the review knows none -- and what
git cannot read -- a revision that is not there, a commit the repository
lost -- leaves the diff shown as it is, or brings the default back when
none was read, and the report says why until the next reading
(`selection-error`).  Choosing ends an Ediff under way, whose files are
the old diff's.  A report opened on a diff since the last review fetches
the versions first (`--sync-and-load`), which say what that is; the other
diffs read the branch while it does.  Ediff's versions and the comments
on the old one are named after the diff (`--side-name`, `--old-phrase`),
and a comment made in a diff whose new side is another commit than the
newest version's records that commit as its revision, so
`--place-threads` carries its line through the diff from there.

The files show as a tree by default
(`harness-ui-patch-review-file-tree`): a directory line with its files'
count and the lines they add and delete, then the files under it by
their names, the directories and files of a directory by name.  t on a
row shows them flat instead, every path whole, in the diff's order.  A
file's mark says whether it was compared in Ediff, by its path and its
blob on the branch, and whether it was approved -- by the same key, so a
file the branch changed again is neither and is reviewed anew.  The marks
are the harness's to keep (`patch-review/viewed`, read when the review is
synced and added to the marks made meanwhile, `patch-review/set-viewed`,
sent as a mark is made, once for the files of `A`), so they are there
after a restart; V (`harness-ui-patch-review-assume-viewed`) asks the
harness to take every file as viewed but those the newest commit changed
-- with a prefix argument, from a commit asked for -- after a question,
and replaces the marks with the answer; the heading says that files were
taken as viewed and not looked at ("unchanged since 7ec4f03 taken as
viewed").  a
approves the file at point, A every file; the heading counts those
viewed and those approved, the threads ("3 open, 2 closed", with the
key that lists them, T) and the drafts that wait for the feedback.  A
file's row counts its threads and says whether it changed since the
reviewer's last comment on it or stayed the same.  Under it are its open
threads, a line each (`change-review-ui-thread-line`: `● 3f9a1c · line
44 (was 42) · Claude: “Because the retry loop…” · 3 comments`), or all
of them with `harness-ui-patch-review-closed-threads`.  RET or a click
on a thread's row compares the file with that line in sight (the row's
`harness-ui-patch-review-where` property); r, x and o act on the thread
as in the threads view, and c comments on the change as a whole.
Threads that no file row shows -- those on the change as a whole and on
files the diff shown does not change, each with its file -- stay in a
block above the files, "Other threads".

RET on a file runs `ediff-buffers` on the two blobs, laid out by
`harness-ui-patch-review-ediff-window-setup`, once it saved the frame's
window configuration and deleted every other window but the report's
side window, which stays for its box (below); without a box beside Ediff
(`harness-ui-patch-review-ediff-box-height` nil) the side window goes
too (`ignore-window-parameters`).  q sets the configuration back. The
report, drawn again meanwhile, gets its window start and point anew,
since its markers in the configuration went with the text they were in,
and a window whose buffer was killed -- the report's, when the task was
decided while Ediff showed -- goes
(`window-restore-killed-buffer-windows`).  N and P read the next file's
blobs, then end the Ediff under way quietly, within
`save-window-excursion`, and start the next in its place, keeping the
configuration to give back.  n is Ediff's next difference, wrapped
(`harness-ui-patch-review-next-difference`): at the last difference it
says once that the next difference is the next file, and the same key
again goes on to it in Ediff.  The control panel's map is a child of
Ediff's with c, r, x, T, TAB, e, a, n, N, P and q (under evil,
`evil-normalize-keymaps` puts it where evil-collection made Ediff's map
overriding) and a brief help of its own
(`ediff-brief-help-message-function`); quitting goes through
`ediff-really-quit` with `ediff-keep-variants` bound, so it asks
nothing, and the review kills the two versions itself.

THE THREADS IN EDIFF.  The threads of the file show in both versions
under their lines, as an overlay's `after-string` at the end of the
line, drawn as the library draws them
(`harness-ui-patch-review--decorate`): in the newest version of the
file, at the place `change-review-placement` gives -- the merge base's
version for a thread on a removed line, the top of the branch's for one
on the file as a whole or whose line is gone.  A thread that moved says
where it was ("line 44 (was 42)") or that its line changed since.  In
either version (`harness-ui-patch-review-lines-mode`, whose map has the
library's for its parent) c starts a thread, a draft, on the line at
point -- on the branch's side it is a line of the branch, on the merge
base's one of the merge base -- and r, x, o, RET and TAB act on the thread
under point (TAB is the key of the major mode where no thread is under
the line); e edits the draft there, or goes to the box.  In the
control panel c comments on the last line of the current difference (at
the merge base for a difference that only deletes), r replies to the
thread there, x closes or opens it, TAB folds the threads the difference
spans (`harness-ui-patch-review--difference-threads`: those placed on a
line it covers, in the version they are in) and T lists all the threads,
d in that view coming back to Ediff at the thread's line.  The threads are
drawn to the room the window that shows the version has: the width of its
lines and its height, which limits a thread
(`change-review-ui-current-size`).  A version is built before Ediff has
windows to show it in, so the review draws the threads again once Ediff
laid the frame out (`harness-ui-patch-review--redraw-sides`), and a
buffer-local `window-size-change-functions` hook
(`harness-ui-patch-review--side-resized`), which redisplay runs when a
window is added or changes its size -- a split toggled with `|`, the box
growing as a long message is typed in it -- only sets a debounced timer;
the timer compares the size the threads were drawn to with the window's
and draws them again when they differ.  A comment is read
in a buffer of its own (`change-review-ui-read-function`; C-c C-c keeps
it as a draft), and the excerpt it records is the change it ends and at
most `change-review-diff-context-lines` lines before it, not from the
middle of another change.

THE DRAFTS.  A comment the user writes is a draft until the task is sent
back; the report counts the drafts, and the views mark them.  The
feedback box is the report's, and C-c C-c sends it as it sends any: the
module adds no sending of its own.  What goes with the box is the
drafts: the harness takes them along with whatever sends the task back
-- the box, a message typed in the task's session, another client --
quoted from the diff above each comment as a reply on a mailing list is,
with the thread each belongs to and how to answer it (see
`patch-review`).  A box left empty sends when drafts wait: the report
sets the popout's `harness-ui-popout-empty-ok-function` from
`harness-ui-review-pending-functions`.  The drafts become sent comments
as the task goes back.

The report stays in the frame while Ediff compares a file, for its
feedback box (`harness-ui-patch-review-ediff-box-height`, a fraction of
the frame's height).  Before Ediff lays the frame out,
`harness-ui-patch-review--keep-box` gives the report's side window the
`no-delete-other-windows` parameter, which `delete-other-windows` --
Ediff's own call too -- honours, and limits the popout: its buffer-local
height limit (`harness-ui-popout--max-height`) becomes a function
returning that fraction, the old value kept for q, so that drawing the
report again does not grow it back to its own share.  The window is the
side window the report shows in (`harness-ui-patch-review--box-window`),
never another window that shows the same buffer: N and P end the Ediff
under way within `save-window-excursion`, and when a hook of
`ediff-quit-hook` sets another window configuration back meanwhile --
Doom Emacs restores the one it saved before Ediff began -- the
configuration that returns has windows again for the buffers that were
killed, each showing the first buffer of the buffer list but the current
one, which is the report's.  Taking such a window for the box kept it
through Ediff's own `delete-other-windows`, and every file after had one
more report in the right split; now it is no box, loses the mark if it
has it, and Ediff takes it like any other window.  Ediff's plain
setup puts the versions and the control panel in the main window above
the side window (`display-buffer-in-direction` bottom is the main
window's bottom).  The window's point is the box's end, which the
popout's own scrolling keeps in sight.  A window that is not selected
loses its point when the popout is drawn again, so the review's own
refresh keeps where such windows had point and puts it back
(`harness-ui-patch-review--window-places`); the popout's panel hook also
lets go of the limit when no Ediff is under way, so a limit left by an
Ediff killed from outside does not stay.  A report closed meanwhile
comes back, as a side window, when the box is wanted.  e
(`harness-ui-patch-review-edit-comment`), in the control panel or either
version, edits your draft under point -- or, with none, selects the
window with point at the end of the box: the box is the popout's, so
editing it is typing, and C-c C-c sends it.
`harness-ui-patch-review-open` on C-c C-d, which the review's minor mode
now has in the report too, selects the control panel of the Ediff beside
the report instead of opening it.  When the task's `:feedback` gets a
round -- the feedback was sent -- the review ends the Ediff, the frame
as it was.

THE ROUNDS BEFORE.  A task sent back before there were threads kept its
feedback as text.  The harness reads those rounds once, when it first
makes the task's set, and turns each comment the reply format finds in
them into a closed thread with an id that follows from where it was
(see `patch-review`), so what an earlier reviewer said shows in the same
views as what they say now, closed; a reply made under a quote of the
agent's words has the quote above it, and the replies typed in the
session outside a round come with `patch-review/import-manual`
(`harness-ui-patch-review-import-manual`, M-x in a task's report, session
or card, asks for it).  The words typed with a later round are kept as a
sent thread on the change as a whole.

OTHER SETS.  The library is not tied to a task.
`change-review-open-threads` opens the threads view of any set,
`change-review-open-diff` the diff view of any version, and
`change-review-open-patches` reviews a file of patches: a mailbox with
an emailed series, `git format-patch` files, a single patch or a plain
diff.  The series becomes a set whose versions are its `[PATCH vN]`, and
whose threads are kept in a file under `change-review-ui-directory`, so
opening the same patches again finds them, a later version of the series
being one more version of the same set.  `change-review-ui-import-reply`
adds the comments of a reply (the region, or a mail saved in a file):
each comment becomes a thread on the line it was under, or a reply in
the thread it answers, authored by the mail's sender; and C-c C-c writes
the drafts as replies to send, a mail for each patch with comments, in
`message-mode`.  To the views, a handed-in task is one more set of
versions, and an emailed patchset is the same thing.

The module follows `task/changed`, `task/review` -- a task back for
review has its branch read again, and the version the harness recorded
-- `patch-review/changed`, and `task/done` and `task/deleted`, which
drop the review: at once when its Ediff does not show, else when q
leaves it.
