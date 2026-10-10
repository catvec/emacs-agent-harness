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
                naming, compaction, handoff, worktree, merge, tasks, tasks-notify,
                supervisor, seed, skills, perms, sandbox, notifications
 Completion     provider, provider-openai, provider-deepseek, provider-claude,
                provider-bedrock, provider-copilot
 Tool calls     tools, tools-fs, tools-shell, tools-ssh, tools-emacs, tools-emacs-eval,
                tools-web, tools-agent, tools-sessions, tools-notify, tools-handin,
                tools-dev
 ------------------------------- bus (lisp/harness-core.el)
 Core           harness.el (loader, reload), harness-core (methods, events, filters,
                promises, modules), harness-util (json, ids, paths), harness-http (curl, SSE,
                binary bodies), harness-policy (settings an administrator fixes)
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
  in the lent Emacs.  Model-written Lisp reaches the lent Emacs only
  through `emacs_eval` (tools-emacs-eval), which the user can turn off
  with `harness-emacs-eval` (on by default): the code runs on the UI's
  only thread, where a blocking call freezes typing and redisplay,
  so a judge model must expect it to return at once, the permission
  chain must allow the call as it would a bash command, and the lent
  Emacs runs it guarded (the user's next key or C-g stops it; it may
  not prompt; it is stopped once it has waited two seconds).  The lent
  Emacs checks the setting itself, so it has the last word.
- Chores of the UI, which any client may do, are asked for with
  `client/request` (below): saving user options to `custom-file`
  (`harness-save-user-option`), reverting buffers after a tool
  writes a file (event `tools/file-written`), and desktop notifications
  (lisp/harness-notifications-desktop.el, see notifications), so they
  show where the user is and a click on one opens what it is about.
- Project roots and file lists (lisp/harness-files.el) are computed on
  both sides with the same code; the UI lists files itself so `@`
  completion uses the user's projectile cache.
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
(harness-define-module 'NAME :doc "…" :requires '(a b) :init #'fn :shutdown #'fn)
(harness-defmethod session/get (id) "Doc." …)          ; registers method `session/get'
(harness-call 'session/get id)                         ; sync; may return a promise
(harness-call-async 'session/get id)                   ; always a promise
(harness-on 'session/updated #'named-fn)               ; events; named fns dedupe on reload
(harness-emit 'session/updated id changes)
(harness-add-filter 'agent/system-prompt #'fn 40)      ; sync value transformer
(harness-run-filter 'agent/system-prompt "" session)
(harness-run-filter-async 'permission/decide decision request) ; async decision chain
```

Async filter gotcha: `harness-run-filter-async` adopts any promise a
handler returns and calls NEXT with its value.  A handler that stores
NEXT to call later (merge holds, budget prompts) must return nil.
`harness-run-filter-async-between NAME FROM TO VALUE &rest ARGS` runs
only the handlers whose priority lies between FROM and TO, inclusive
(the perms module re-decides a waiting prompt through the stages after
the jail with it).

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
subscribers with named functions, and make `:init` idempotent.
`harness-reload` compiles every file first and refuses to load anything
if one fails.  It loads harness.el, the core files, the libraries of
lisp/ (`harness--library-files`: files, the Emacs endpoint, desktop
notifications, server, revision) and the modules, so a module never runs against
a library as it was before an update; a file added to lisp/ that both
sides load belongs in one of those lists.  Records made before a reload
keep their layout: a slot added to a struct goes last and is read in a
way that tolerates records without it (see `harness-acp--client-get`),
or the module drops its stale records (see
`harness-provider-claude--drop-stale-entries`).  After a reload the
`harness/reloaded` event fires and the UI redraws every session buffer.

## Modules of your own

A module of the user's own lives outside the harness's tree, in a
directory of `harness-extra-module-directories` (absolute, or relative
to `user-emacs-directory`).  It is bound by this document as the
harness's own modules are.  `harness--module-files` decides what loads
where:

- Every `harness-NAME.el` of such a directory is module `NAME`,
  filtered by `harness-enabled-modules` and `harness-disabled-modules`.
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
(:id "uuid"  :name "short title or nil"  :kind main|fork|btw|subagent
 :project "/abs/root/"  :cwd "/abs/dir/"  :host nil|"/ssh:user@host:"   ; TRAMP prefix
 :worktree nil|"/abs/worktree/"
 :model "PROVIDER:MODEL"            ; e.g. "claude:claude-fable-5-1"
 :permission-mode ask|accept-edits|auto|yolo
 :thinking nil|"low"|"medium"|"high"|"xhigh"|"max"
 :non-interactive nil|t             ; its own switch, from harness-non-interactive at creation
 :status idle|running|blocked|inactive
 :parent-id nil|"uuid"  :fork-node nil|"node-id"
 :created FLOAT  :updated FLOAT
 :usage (:input N :output N :cache-read N :cache-write N :cost F :list-cost F :context N :turns N
         :last-output N                                         ; the output of the request :context sizes
         :billing api|subscription|extra-usage :plan "max"     ; billing and plan of the latest call
         :cache-at FLOAT :cache-model "ID" :cache-ttl N)  ; the last request that used the prompt cache
 :cache nil|(:at FLOAT :ttl N :expires FLOAT :model "ID")  ; derived: when the prompt cache lapses, whose it is
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
`session/ext-changed`.

`:usage :context` is the input size of the last request (prompt tokens
incl. cache) and `:last-output` what that request wrote, which the next
one sends back: the conversation holds about the sum of the two, which
the UI shows as the context in use and colours against
`:context-window`.  While a turn runs, the usage module's live count
stands in for both and for `:output` (see "usage", Live token count).
`:cost` is what the session's calls were billed and `:list-cost` the
same calls at API prices (they differ when a subscription paid); see
"Usage record".

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
session still knows.  `:cache` is derived from them each time the
session is described, like `:context-window`: `:ttl` from
`provider/cache-ttl` for the stamp's model (the reported lifetime, else
the configured one), `:expires` = `:at` + `:ttl` and `:model` the
stamp's model.  Past `:expires` the next request sends the whole
context again at the uncached rate, which the chat warns about above
the compose box (`ui-cache`, see "Chat buffer").

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
 ;; tool-result:
 :call-id "toolu_…" :output "text" :is-error BOOL :attachments (ATTACHMENT…)
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
```

ATTACHMENT = `(:path "/abs" :size N :mime "…" :name "display")`.

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
  or wrote the prompt cache was made (a float time) and the seconds the
  provider said it keeps that cache.  Claude Code gives both: the time
  of the turn's last main-conversation `message_start` that used the
  cache, and 3600 or 300 by whether the request wrote to the one-hour
  or the five-minute cache.  Without them the record's own arrival
  stands for the time, and the configured lifetime for the TTL (see
  "Session" and `provider/cache-ttl`).
- `:model`, optional, is the model the request was sent to, which a
  step that ends after a switch tells from the session's; the cache the
  request used is that model's.  `:cache-reset`, optional, says the
  conversation starts over (a compaction's summary replaces it): the
  record drops the session's cache stamp instead of setting it.
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
(the level BTWs start at, default "low"; nil for the session's),
`harness-allowed-directories`, `harness-sandbox-policy`,
`harness-non-interactive`, `harness-supervisor`.  A module defines some
of them, `harness-supervisor` the supervisor module: until it is loaded
the key takes part in nothing, and every reader of the layers skips it
(`harness-config--layered-keys`).  `harness-budget` has a global value
only: it is one budget for all sessions together (see usage).

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
safety, task board, notifications, models and services);
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
- `project/files ROOT &optional QUERY LIMIT` → promise of relative paths,
  fuzzy filtered; nil outside a project.  Never blocks: projectile's
  cache when it has the project, else an asynchronous listing
  (projectile's command, or `git ls-files`) stored back into projectile's
  cache.  No cache of its own.  Implemented by lisp/harness-files.el.

### store

Persistence under `harness-state-directory`:
- `store/save NAME OBJ`, `store/load NAME` (JSON files, atomic write).
- `store/append NAME OBJ`, `store/read-all NAME` (JSONL).
- `store/sqlite` → open built-in sqlite handle for `usage.db` (nil when
  Emacs lacks sqlite; callers fall back to JSONL).
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

- `session/create &rest PLIST` — `:cwd` required; `:name :model
  :permission-mode :thinking :kind :parent-id :host :worktree`,
  `:context-window` to set the session's own window and
  `:context-window-limit` to cap its model's window at a number of
  tokens (see the compaction section), `:ext` to give it the settings of
  modules that keep some (see `session/set-ext`).  Fills
  project, defaults from `config/get`.  A `btw` session without
  `:thinking` takes `harness-btw-thinking` when its model offers that
  level (the catalogue lists it in `:thinking-levels`), else
  `harness-thinking`.  → session.  Event `session/created ID SESSION`
  fires once the record is stored.  A subscriber may change the session
  meanwhile (the supervisor module sets its `:ext`), so `session/create`
  announces (`session/changed`) and returns the session as the
  `session/created` subscribers left it, not as it was when they were
  told: its maker and the UIs see what they set, from the start.
- Settings a policy fixes ([policy.md](policy.md)): when the policy sets
  `harness-model`, `harness-permission-mode`, `harness-thinking` or
  `harness-non-interactive`, every session's copy is the policy's value
  (`harness-session--policy-options`; a BTW's thinking aside, which
  follows `harness-btw-thinking`).  `session/create` and `session/fork`
  give it whatever PLIST asks for, a record loaded from disk gets it,
  and a reload (`harness/reloaded`) brings every session in line with
  the policy as it is then, with `session/updated`.
  `session/update`, `session/set-all` and the task board refuse another
  value with "OPTION is set by policy (FILE) and cannot be changed",
  changing nothing; `harness-session-check-policy` is the check, which
  also refuses a model `harness-allowed-models` does not allow.
- `session/get ID`, `session/list &optional FILTER` (`:project :status
  :kind :parent-id :active`), `session/delete ID` (its temporary
  directory goes too).
- `session/tmp-dir ID` → the session's own temporary directory, made if
  missing, or nil.  Every local session has one:
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
  included: a bulk change must not reach a task that is over.  It is
  the selection of `session/set-all`, `handoff/check-all` and
  `handoff/switch-all`.
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
  `set_non_interactive` tool use, with `(:active t :tasks t)`.
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
- `session/btw ID &optional NAME`: a BTW side conversation over ID, a
  new, empty `btw` session sharing nothing with ID or with any other
  BTW (no nodes, no fork node, no provider state, no directory grants).
  It takes ID's cwd, project, host, worktree, model and permission
  mode; `:parent-id` is ID only so lists show it under ID.  It thinks
  at `harness-btw-thinking` as configured at ID's cwd ("low" by
  default, so quick questions get quick answers) when the model offers
  that level, else at ID's level.  Returns the new session.
- `session/nodes ID &optional (:limit N :before NODE-ID)` → path nodes,
  oldest first; `session/node ID NODE-ID`; `session/tree ID` → every
  node of the family (session + ancestors + forks) as a list with
  `:session` set, plus `:sessions` summaries.
- `session/append ID NODE` → node with id/ts/parent filled; advances head.
  Event `session/node-added ID NODE`.
- `session/update-node ID NODE-ID PLIST` (tool result streaming, titles).
  Event `session/node-updated ID NODE`.
- `session/set-head ID NODE-ID` — time travel: the next message
  continues from NODE-ID, with a provider conversation cut to match (see
  "Node").  Refused while ID runs a turn.  Event `session/head-moved ID NODE-ID`.
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
  `session/queue-remove ID QID`, `session/queue-take ID` → items, cleared.
  Event `session/queue-changed ID ITEMS`.
- `session/pending-add ID REQUEST` → id; `session/pending-resolve ID PID ANSWER`;
  `session/pending ID`.  Event `session/pending-changed ID ITEMS`.
  Status becomes `blocked` while anything is pending.
- `session/usage-add ID USAGE &optional CONTEXT` → accumulated usage.
  A record of a request that read or wrote the prompt cache stamps the
  totals' `:cache-at`, `:cache-model` and `:cache-ttl`; one that used
  none, or one with `:cache-reset` (a compaction), clears them (see
  "Session").  Event `session/usage ID USAGE-TOTAL RECORD`.
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
  changed, and a message that needs no change comes out as it is.
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
  :capabilities PLIST   ; static defaults, merged with per-model ones
  :tiers PLIST)         ; a model per tier, see below
```

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

Model tiers: `:tiers' names a model (`:cheap' `:balanced' `:frontier'
are the common ones) by a name, id or regexp, so the harness can pick a
model on its own - the auto-mode judge asks for the cheap one -
without the user naming one.  A tier the provider does not name, and a
provider that declares none, falls back to its own catalogue sorted by
price: `provider/tier-model MODEL-ID &optional TIER' returns the `:cheap'
one by default, or nil when the provider is unknown or lists nothing
(the caller then uses what it has).  MODEL-ID may also be a provider id
alone.  This is what ties the judge to the
session's provider.  Claude, DeepSeek, Bedrock and Copilot name their
tiers; the dynamic OpenAI-compatible catalogues fall back to price.
The other way round, `provider/model-tier MODEL-ID` says which tier a
model is in its provider: the one `:tiers' names it for (`:balanced'
first, then `:frontier', then `:cheap', when several do), else its
place in the catalogue by price (cheapest third `:cheap', dearest third
`:frontier'), else `:balanced'.  So Claude's Fable 5.1, which no tier
names and which costs the most, is `:frontier'.  The fallback module
maps a model to "its model of similar ability" at another provider
through the two.

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
when it is not `harness-cache-ttl`: DeepSeek declares 10800).

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
thinking (the auto-mode judge sends it); Claude Code, which takes no
`:max-tokens`, then runs the CLI with `MAX_THINKING_TOKENS=0`, and
other providers may ignore it.

A REQUEST with `:ephemeral t` is a one-off question, such as the
auto-mode judge's.  The provider answers it from the request alone, as
if nothing came before it and nothing comes after it: it brings no
earlier conversation, keeps none, and loads no context of its own
(project instructions, memory).  Providers that send the whole request
every time (the HTTP APIs) already work that way.  Claude Code starts
a throwaway CLI process for it, and Copilot a throwaway session (see
below).

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
`provider/close MODEL-ID SESSION-ID` (free what the provider keeps for a
session id of a request that is not a session of its own, such as a task
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

The one exception is WebSearch, which stands in for web_search
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
the tool loop lasts.  `harness-http-request` takes `:binary t` for such
framings: the response then reaches `:on-chunk` as unibyte strings.

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
  `tool-call` whose `:respond` answers `session.tools.handlePendingToolCall`,
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
:meta PLIST)`.

- `tools/list &optional SESSION-ID` → TOOL-SPECs `(:name :label
  :description :schema :kind :coalescable)`, filtered through sync
  filter `agent/tools` (value: list of names; args: session).  Without
  SESSION-ID every registered tool: how UIs learn the labels.
- `tools/execute SESSION-ID CALL` (CALL = `(:id :name :input)`) → promise of
  RESULT.  Pipeline: lookup → `permission/decide` (async filter) →
  handler (with `harness-tools--timeout`) → context-bomb guard → sync
  filter `tools/result` → events `tools/started`, `tools/finished`.
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
  saved to `harness-state-directory/outputs/CALL-ID.txt` and replaced
  by the head plus an instruction to range-read that file.
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
  The agent keeps `:denied t` in the `:meta` of the call's tool-result
  node, so a view can tell a call the permission system refused, which
  never ran, from one that ran and failed (`harness-ui-tool-outcome`).

### perms

Async filter `permission/decide`: value is a DECISION
`(:behavior allow|deny|ask :reason "…" :input UPDATED :final BOOL)`,
args are the REQUEST `(:session SESSION :tool NAME :input PLIST :kind KIND
:paths (…))`.  Chain (priority): 5 dir-request, 6 away-request, 6
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
  checkout of a worktree), and for a remote path.  For an agent's
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
- What a shell command reaches: the bash tool's `:paths` is where it
  runs, which is all the jail checks (the sandbox confines the command,
  and the mode and the judge read it whole).  For an `exec` call with a
  `:command`, `harness-perms--command-paths` reads the paths the
  command line names: a best-effort word scan (quotes, backslashes,
  comments, `;` `&` `|` `(` `$(` and backquotes, redirections) that
  keeps words that are absolute, start with `~` or `$HOME`, or with
  `./` or `../`, and the values of `--option=…` and `NAME=…` words;
  not the programs it runs (the first word of a command, after
  assignments, keywords and prefixes such as `sudo` or `xargs`), not
  `/dev/null` and the like, and on this machine not an absolute word
  whose first directory does not exist, so a `/api/v1` in a grep is no
  path (on a remote host nothing is looked up, and `~` words are left
  out).  The paths are on the host the command runs on, its
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
  directory needs no grant and cannot be revoked.
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
  :revocable)` plists, for the directory buffer), `permission/allowed-dirs SESSION-ID`
  (the full effective root list), `permission/rules SESSION-ID`
  (`(:mode :non-interactive :auto-allow :session :always :roots :inspect :skills)`:
  `:auto-allow` holds the inspection tools too, `:inspect` the
  directories of the harness itself and `:skills` the skills
  directories every call that only reads may read),
  `permission/pending SESSION-ID`, `permission/reveal-file SESSION-ID
  FILE` (see above).
- Session directory grants are stored on the session record
  (`:allowed-dirs`), so they survive restarts and forks inherit them.
- Rules are plists `(:tool NAME-or-nil :kind KIND-or-nil :path PATTERN-or-nil
  :behavior allow|deny)`; session rules live in memory, always-rules in
  `harness-perms-rules`.  A rule with a `:path` (absolute, or relative to
  the session's cwd) applies to calls with paths only: an allow rule when
  the pattern holds every path of the call, a deny rule when it holds
  any.  For a shell command an allow rule needs every subject path (the
  ones it names outside the session's directories, else where it runs),
  so a rule for the project no longer lets `rm -rf ~` run in it; a deny
  rule holds when any path it names, inside or out, or where it runs
  lies in the pattern.  The mode stage checks them first, before the
  auto-allow list and the mode.  A tool prompt (the mode asking, or the
  auto judge objecting) is about the call itself, whose paths the jail
  already let through: it offers no pattern, and its allow-session /
  allow-always / deny-always answers record `(:tool NAME :behavior B)`,
  for every call of the tool, a `:pattern` in the answer notwithstanding.
- Events `permission/requested SID PENDING` (PENDING `(:id :kind permission
  :payload (:tool :input :kind :paths :call-id :title :options))`, plus
  `:dir`, `:pattern` and `:reason` for a directory prompt; a tool
  prompt's `:paths` are its subject paths, and a shell command's prompt
  has `:cwd`, where it runs; a confirmation has `:confirm t` and its own
  `:reason`; UIs offer only the listed `:options`, and
  show a pattern only when there is one),
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
  (an allow or a deny for the session or always on a tool prompt, a
  deny for the session or always on a directory prompt) or a directory
  granted (allow-session or allow-always on the jail's prompt or
  `request_directory_access`) appends a hint
  (`harness-perms--note-recorded`, through `session/append` before the
  call goes on, so it sits under the call) saying what, such as
  "Always allowing every bash call, in every session", with the record
  in its `:meta` `:permission` (see Node).  A rule or a grant that was
  there already gives a note with nothing to undo (no `:undo`, and the
  text says "already so").  allow-once records nothing and gives no
  note, the turn grant of the agent's own request included.
- `permission/undo SESSION-ID NODE-ID` → `(:outcome undone|changed|gone|none
  :message "…")` takes back what note NODE-ID recorded and nothing
  else: the decision on the call it answered stands.  It marks the
  note (`session/update-node`, `:undo` OUTCOME and `:result` the
  message), and a note tried already returns what it got and changes
  nothing (`none` for one with nothing to undo).  A rule is looked up
  by value, the rule as recorded first, then one equal in substance
  (`harness-perms--rule-key`: tool, kind, path and behavior, compared
  trimmed and with symbols as strings, so a rule Settings saved back
  still counts); `undone` removes it from the session's rules or from
  `harness-perms-rules`, saved.  A rule for the same tool and path that
  says something else since (edited in Settings, say) is `changed` and
  stays, and with none left the outcome is `gone`; session rules live
  in memory and a fork starts without them, so that is what a session
  note gets after a restart, or in a fork, which copies the note.  A
  directory: the entry recorded, or one that expands to it, is removed
  (`permission/dir-revoked`); an entry that still covers it, a parent
  put in its place say, is `changed` and stays; else `gone`.  The
  message says what happened and why.
- Saving `harness-perms-rules` or `harness-allowed-directories` (an
  answer, `permission/allow-dir` with `always`, a revoke, an undo)
  emits `config/changed KEY VALUE global nil`, as the config module
  does, so an open settings page shows the change.
- Modes: `ask` (reads inside the jail allowed; everything else asks),
  `accept-edits` (reads/writes inside the jail allowed; exec/net ask),
  `auto` (reads inside the jail allowed; a cheap model,
  `harness-perms-auto-model`, decides the rest with a reason; falls back
  to ask).  The judge model defaults to `auto', which asks the session's
  own provider for its `:cheap' tier (`provider/tier-model'), so a
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
  So are the tools in `harness-perms--inspection-tools`, which only
  inspect the harness or the user's live Emacs: `emacs_buffers`,
  `emacs_buffer`, `emacs_windows`, `emacs_describe`,
  `emacs_find_definition`, `emacs_messages`, `session_info`,
  `session_list`, `session_read`, `session_search`, `session_history`,
  `session_wait`, `task_list`, `task_wait` and `notification_providers`.
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
  (CLAUDE.md).  A judge's denial carries `harness-perms-judge-deny-hint`.
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

### sandbox

- `sandbox/wrap CWD COMMAND-LIST &optional (:network t :writable (…) :readable (…) :read-only nil)` →
  command list (bwrap / systemd-run / plain).  `sandbox/status` →
  `(:backend bwrap|systemd|none :available (…) :policy …)`.  Fails closed
  when `harness-sandbox-policy` is `required` and no backend exists.
  Without the sandbox module the bash tool fails closed for `required`
  too (`harness-tools-shell--wrap`), rather than running the command
  unconfined.
- `:read-only`, for a caller that needs a command to change nothing (a
  supervising session's shell, which only looks), mounts the working
  directory, the git directories and every `:writable` entry read-only
  as well, so the command writes nothing but the sandbox's private
  /tmp.  It fails closed whatever the policy: where the command would
  run unconfined, with the `off` policy, in a remote CWD or with no
  backend, `sandbox/wrap` signals `harness-sandbox-unavailable` instead
  of returning COMMAND.  `sandbox/confined-p CWD` says beforehand
  whether it can be had.
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
  DEST)` mounts, `ro` for a readable directory and `rw` for a writable
  directory or file, each shown where it is named, where its symbolic
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

### agent

- `agent/prompt SESSION-ID BLOCKS &optional OPTS` → promise of
  `(:stop-reason …)`.  Idle session: starts a turn.  Running session:
  steering — the text is queued and injected at the next step boundary
  (appended to the next tool result, or sent as the next user turn if
  the model stops first), and only once.  OPTS `:queue` true only
  queues, even while a turn runs.  OPTS `:from`, when the user is not
  the sender, is the sender plist (see "Node") kept on the message's
  node (and on a queued item).  An empty message is refused.  An
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
- `agent/send-queue SESSION-ID` — sends every queued item as one turn;
  the message is the user's when any item is, else from the first
  item's sender.
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
  fallback module switches the model and retries.  A turn retries at
  most `harness-agent--max-error-retries` (8) times; otherwise, and
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
  A turn has no step limit: long unattended work is the point, and the
  loop ends when the model stops, the provider errors or hits its
  output limit, the user cancels, or an `agent/step` filter (a merge
  hold) pauses it at a boundary.  Automatic compaction runs between
  turns (`agent/before-turn'), not inside one, so a native-provider
  turn that outgrows the window reaches the provider's own error;
  budgets refuse new turns.
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
- `usage/summary &key group-by since until project session model billing` → rows
  `(:key :input :output :cache-read :cache-write :cost :list-cost :calls)`;
  group-by `project|model|day|hour|session|billing` (billing keys "api",
  "subscription", "extra-usage", "" when unrecorded); sorted by list
  cost.  `:cost` is what was billed, `:list-cost` the same usage at API
  prices (rows from before list costs count their cost).  By project a
  row also has `:main`, the main checkout its project belongs to
  (`harness-files-owning-checkout`, resolved here so the UI never reads
  the disk for it): a linked git worktree's, such as a task's, is its
  repository's main checkout, also once the worktree is removed or git
  pruned its registration; any other project's is its own root, and the
  row without a project has "".
- `usage/budgets`, `usage/set-budget BUDGET`, `usage/remove-budget ID`,
  `usage/budget-status ID &rest (:now)` (ID may be "session:SID" for a
  session's implicit budget) → `(:budget :spent :amount :remaining
  :fraction :hard :per-day :days-left :period-start :period-end
  :baseline :reported :sources)`;
  `usage/session-budgets SID` (every budget that applies to the
  session), `usage/project-budgets ROOT` (the project budgets of ROOT
  and the period budgets of everything or of ROOT, as statuses; what
  the task board shows), `usage/plan-budget AMOUNT PERIOD DAYS`,
  `usage/totals`, `usage/series (:bucket day|hour …)`, `usage/record ROW`.
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
- Hard budgets block via `agent/before-turn`; soft ones emit
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
  `session/list` says lived in the period.  A node is counted in the log
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
  task's project, sorted: what the report can be narrowed to.
- `insights/narrative &key since until project period refresh` →
  promise of `(:summary :themes :patterns :friction :suggestions :model
  :at :stale)`, or `(:skipped TEXT [:error t])`.  A model of the user's
  provider (`harness-insights-model`, `auto` the cheap tier of
  `harness-model` as configured for the project) gets a digest of the
  REPORT (figures, and each session's kind, name and first request,
  at most `harness-insights--prompt-chars` characters) and answers in
  JSON.  One `provider/complete` call, `:ephemeral t`, `:no-thinking t`,
  in `insights/` under the state directory, cancelled after
  `harness-insights--narrative-timeout`; its cost is recorded with
  `usage/record` under the project, or none.  Summaries are kept in
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
another.  `harness-fallback-models` (global, *Models and services*) is
the order of preference, first used to last: each entry a provider id,
standing for that provider's model of similar ability (the tier of the
session's model, see `provider/model-tier`), or a model id used as it
is.  nil turns the switching off; running out is still noticed, shown
and hinted.

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
- Choosing: a session's own model comes first; a session moved by the
  fallback remembers its own (`:original`).  When it is out, the first
  entry of `harness-fallback-models` whose model is neither marked nor
  that of an unregistered provider wins.  `harness-fallback-choose
  SESSION` returns `(:model ID :entry ENTRY :reason …)`, or nil.
- Switching: `agent/before-turn` (priority 10, before compaction)
  moves a session whose model is out to the chosen one, and back to its
  own once that works again; `agent/step-error` marks what ran out,
  moves the session and retries the step, so a turn, and a task, carry
  on.  The model changes through `session/update` (`:silent`) with a
  hint of its own ("Claude Code is out of quota until 19:00: carrying
  on with DeepSeek-V4-Pro"), and `fallback/switched SID FROM TO WHY`
  (WHY `out` or `back`).  A model changed by anyone else forgets the
  session's own; a fork takes over its parent's.  With nothing left the
  turn ends with its error and a hint naming every provider that is
  out and when it resets.
- Notifications (`notification/send`, source "fallback"): low urgency
  when a provider runs out and sessions move on, normal when nothing is
  left.
- `fallback/status` → `(:models (ENTRY …) :marks (MARK …) :moved
  ((:session SID :original MODEL :model MODEL) …) :enabled BOOL)`,
  ENTRY = `(:entry STRING :provider ID :model MODEL-OR-NIL :label
  :provider-label :registered BOOL :mark MARK-OR-NIL :tiers
  ((:tier "cheap" :model ID :label …) …))`, `:tiers` for a provider
  entry only.  `fallback/clear KEY` forgets the mark KEY (a provider's
  forgets its models' marks too); → non-nil when one went.
  `fallback/mark KEY &rest (:kind :until :reason)` marks by hand.
  Event `fallback/changed` after any mark or session record changes.

### compaction

- `compaction/compact SESSION-ID &optional OPTS` → promise of the
  `compaction` node, which stands in for the conversation from then on:
  `session/messages` starts at it, as a user message, followed by the
  unanswered user messages carried over after it.  OPTS `:kind` (one of
  `harness-compaction-kinds`) says what it holds:
  - `summary` (the default): the session's model (OPTS `:model`
    another) summarises the conversation, and the message reads
    "Summary of the conversation so far: ...".  OPTS `:context` is
    `full` (the default) or `sample`, which keeps only the first and
    last few messages (`harness-compaction--sample-head`/`-tail`) with a
    user message saying how many were left out: a bound on what a
    summariser sent the conversation as text costs.  A summary of a
    sample is a brief one.
  - `brief`: a summary of a sample, written by OPTS `:model`, else
    `harness-compaction-brief-model` (`auto`, the default: the cheap
    tier of the session's provider, `provider/tier-model`, else the
    session's model; nil: the session's model; or a model named), and
    ending in a note that it was written from only the first and last
    messages and may lack what came between
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
  Every kind but `fresh`, whose note says so already, ends in a line
  pointing the model at the session_history tool
  (`harness-compaction-history-tool`, `harness-compaction--history-note`):
  the conversation it replaced is still on record.  The line is left
  out when the session's model does not have the tool
  (`harness-compaction-history-p`, from `tools/list`).
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
  a second call returning the running promise; OPTS `:idle` refuses a
  session running a turn (`agent/running`), whose turn would go on
  writing after the conversation it replaces, as compacting by hand
  does.
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
  (`harness-compaction--summary-output`).  A transcript and a fresh
  start cost nothing and leave their note (`:after`) in place of the
  context.
- Settings (section "Compaction"): `harness-compaction-kind`, the kind
  automatic compaction makes (`summary`), and
  `harness-compaction-brief-model`.
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
  no `:cache` never is.
- The choices (`harness-cowboy-choices`): `brief`, `summary`,
  `transcript` and `fresh` compact as `compaction/compact` does, with
  `:meta (:cowboy (:choice C :by BY))`, before the message; `carry-on`
  sends the conversation as it is; `hold` stops the turn (`:proceed`
  nil, reason "not now: …"), the message staying in the transcript to
  go with the next one.  A summary that fails falls back to `transcript`
  (`:fallback` in the meta), and that to `carry-on`, each said in a
  hint: the message always goes unless held.  A hint says what went
  first and why ("as you chose", "the default for a session that does
  not wait for you", …).  While the compaction runs the session is
  `running` with the activity `(:phase compacting)`
  (`agent/note-activity`).
- Asked unless `harness-cowboy-ask` is nil or the session is
  non-interactive (the policy's `harness-non-interactive`, else the
  session's own `:non-interactive`, else the config, as perms decides):
  `question/ask` puts a question pending on the session, which is
  blocked on it.  Its payload holds the question, the options with
  their costs (`compaction/estimate`), `:allow-free-text`, the message
  waiting as `:waiting-message` `(:text :from)`, and `:cowboy`: `(:at
  :ttl :expires :cache-model :model :model-label :context :messages
  :carry-on :carry-on-cached :from :preview :default :history
  :choices)`, each choice `(:choice :label :what :cost :cost-text :by
  :after)`.  Clients that know it draw it (ui-cowboy); the others show
  an ordinary question.  The answer is read by
  `harness-cowboy-parse-answer`: a choice's name, label, option as
  offered, number, key or words naming it, and "always" with any but
  `hold` makes it the default and turns asking off (`config/set` of
  `harness-cowboy-default` and `harness-cowboy-ask`).  An answer that
  names no choice asks again; a dismissed question holds the message.
  `session_control` refuses to answer it for another session's agent.
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
  `hold`), emits `cowboy/decided SID CHOICE BY`, adds a hint and, unless
  the choice is `carry-on`, compacts as the gate does (`:meta (:cowboy
  (:choice C :by BY))`, the fallbacks included).  It does not mark the
  session busy: no turn is running.  It resolves with the choice taken,
  a symbol, and never rejects: an error is logged and resolves nil.
  OPTS: `:by` SYMBOL, BY, default `cold-start`; `:why` STRING, which
  opens the hint in place of "Prompt cache cold since HH:MM", a time a
  session with no cache could not give (for example "No prompt cache on
  MODEL holds the supervisor's conversation").  The hint ends "the
  default for a session no warm cache holds (harness-cowboy-default)".
- Settings (section "Cold cache"): `harness-cowboy-ask`,
  `harness-cowboy-default`, `harness-cowboy-min-context`.

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
  so `:tasks` takes in the sessions of current tasks).
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
  `:model`: the first and last few messages): use it when the old
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
  `:cheap` tier, `provider/tier-model`) with `:ephemeral t`,
  `:no-thinking t`, a 40-token budget and no provider state, so the
  hosted providers answer it apart from the session's conversation (a
  CLI process of its own for Claude Code, a throwaway session for
  Copilot) and the question never lands in it.  It fails after
  `harness-naming--timeout` (60) seconds, cancelled, so a provider that
  never answers does not keep a session nameless.  A session still
  nameless when a later turn starts (its naming failed) is named then,
  and so is a nameless session whose turn runs when the harness reloads
  (`harness-naming--name-running`); btw and subagent sessions never are.
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
  `provider/close`d once it settles.  Nothing is stored and no session
  hears of it; it rejects with a message (blank TEXT, no model, provider
  error, no usable title, timeout) and never signals.  Task mode names a
  task from its prompt this way as it is submitted.
- Sync filter `naming/system-prompt` (value string, args the session, or
  `naming/title`'s OPTS) lets modules add to
  `harness-naming--base-system-prompt` per session (tasks ask for ticket
  titles, for a session of a task and for OPTS with `:task`).
- Sync filter `naming/auto-p` (value the verdict, args session) can hold
  the automatic naming of a session off: tasks do while the title of the
  session's task is on its way, which then names the session.

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
    runs from the worktree let go of it: tools-dev stops the Emacs that
    `open_harness` started there.
  - `worktree/prune` runs `git worktree prune -v` outside the sandbox,
    where git sees every worktree, so it prunes only worktrees really
    gone, and skips locked ones as git does.  It returns git's lines plus
    a `Kept ...` line for each locked worktree whose directory is missing
    (`worktree/remove` takes those away).
  - Worktrees made before locks: `worktree/lock-existing ROOT` locks the
    registered worktrees in the directory the harness puts its worktrees
    in (`harness-worktree-directory-function`, ROOT/.worktrees/ by
    default) that have no lock, whose directory exists, and that the sync
    filter `worktree/lock-existing-p` (value t, args ROOT WORKTREE) does
    not turn down; the tasks module turns down merged tasks' worktrees.
    The main checkout and foreign worktrees are never touched.  On
    `harness/started` and `harness/reloaded` it runs for the main
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
  into the target's HEAD off to the side; a clean result becomes a merge
  commit (`git commit-tree`, message as `git merge --no-ff` writes it)
  and the checkout moves onto it with `git merge --ff-only`, which git
  refuses, changing nothing, when it would overwrite uncommitted or
  untracked work there or a merge is already in progress (the merge
  fails; a HEAD that moved meanwhile is merged again).  On conflict the
  target is untouched and the lock passes on at once, and the target's
  commit is to be `git merge`d into the child's branch, in its own
  worktree.  By default (`harness-merge-conflict-resolver` `fresh`) the
  harness starts a fresh `subagent` session for it -- a child of the
  child session, in its worktree, with its settings and
  `harness-merge-resolver-model` or its model -- prompted (from
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

### tasks

Task mode: one session per task.  TASK =
`(:id "t-…" :project ROOT :cwd DIR :prompt "…" :attachments (…) :name "title or nil"
:state pending|refining|active|merging|review|done
:column pending|needs-input|active|review|merging|done
:backlog BOOL :note "the words a backlog task was written up from" :refined F
:priority low|medium|high
:session SID :outcome nil|end-turn|error|cancelled|duplicate|merge-failed|merged|…
:waiting nil|"what the session started runs outside its turn"
:error "…" :duplicate-of ID :main-tree BOOL :worktree DIR :branch NAME :base NAME :merge-status nil|queued|merging|conflict
:merge-queued F :conflicts (FILE…) :merged BOOL :archived BOOL :created F :started F :finished F
:verified BOOL :verified-at F :feedback ((:text "..." :at F) ...))`.
`:column` is derived on every read: `needs-input` when the session is
blocked on a request or the task stopped part way, `merging` while its
branch holds a place in the merge queue (`:merge-status` is queued,
merging or conflict; `:merge-queued` is when it joined, which orders the
board's section), `review` while its finished work waits for the user's
verdict.  `:priority` is one of `harness-tasks-priorities`, a symbol
in memory and a string on disk and the wire; every read has it, and a
record from before priorities reads `medium` without being rewritten.

- `task/submit CWD PROMPT &optional (:attachments :model :permission-mode
  :thinking :non-interactive :supervisor :refine :main-tree :priority)` → task; it
  starts when one of its project's `harness-tasks-max-running` slots is
  free.  The limit is per project: every project (a task's `:project`,
  the main checkout, else its `:cwd`) has that many slots of its own,
  and the scheduler (`harness-tasks--schedule`) starts each project's
  queued tasks in start order (`harness-tasks--start-order`: highest
  `:priority` first, oldest first among equals) while that project has
  slots left (`harness-tasks--free-slots PROJECT`), so a project at its
  limit holds up only its own tasks.  Only top-level sessions take slots
  (`harness-tasks--holds-slot-p`): a task holds one while it starts,
  and while it is `active` with its own session -- one without a
  `:parent-id` -- running or blocked mid-turn, or idle with work it
  left running (`:waiting`, a supervisor's workers say).  The sessions working for
  a task never take one of their own: its sub-agents and forks, and the
  merge queue's conflict resolvers (`subagent` children of its session).
  Nor does the merge queue, which the limit never holds up: a task in it
  (`merging`) holds no slot, even while its own session commits or
  resolves the conflicts, so a waiting task starts meanwhile; nor does
  writing a backlog task up (`refining`).  `:priority` is `low`, `medium`
  (the default; `med` reads as it) or `high`, a symbol or a string in
  any case; anything else is refused before the task is made.  A
  priority only orders the queue: it never stops a task at work, and a
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
  With `:refine` the task goes to the backlog instead (below).
  With `:main-tree` it works in the project's main checkout: no worktree
  is made, it gets no branch, and nothing merges when its turn ends, so
  it can touch the checkout itself -- cleaning up uncommitted changes,
  say.  The flag is explicit, never the default; the `task_submit` tool
  offers it as `main_tree` and the board as a worktree switch beside the
  other new-task settings.  A refined (`:refine`) task keeps it for when
  it starts, and its session, made at the task's directory for the
  write-up, then stays there rather than moving into a worktree.
- A task's session also runs on `harness-tasks-context-limit' (384000)
  tokens of context at most, so it compacts earlier than an interactive
  session; nil gives it the whole window.  A refined task's write-up
  session, and a session adopted by `task/adopt', get it too.  A
  provider that compacts on its own side keeps deciding by itself,
  except Claude Code, which is spawned with the limit as
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' (see the claude provider).
- Backlog refinement (once called grooming): a `:refine` task is
  `refining` while a session at its directory -- `ask` and
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
  `pending` with `:backlog t`: the scheduler never starts it, only
  `task/start`, so the backlog survives restarts.  A turn of a backlog
  task's session before it starts is feedback (`task/prompt`) and
  rewrites the write-up; a write-up that stops needs input (restarts:
  below).  `task/refine ID &optional TEXT` refines a queued task or
  writes one up again.  Starting continues the same session: in git it
  moves into the task's new worktree (`session/update :cwd :worktree`),
  its provider conversation is dropped (the Claude CLI keeps
  conversations per directory; the new one gets the transcript, the
  write-up's conversation, as text: see "Replay") and it is prompted with
  `harness-tasks--start-message`, the write-up and the quoted note, under the
  task's own settings.  Dropping a backlog task deletes its session.
  The messages task mode composes itself (starting a written-up task,
  the restart resume, the nudge to finish a write-up) are marked as
  from `harness-sender-system "tasks"`; the task's prompt and
  `task/reject` feedback are the user's, and so is a `task/prompt`
  follow-up unless its OPTS `:from` names another sender:
  `task_control`'s message names the calling session.
- `task/adoptable &optional CWD` lists the project's open sessions that
  are not tasks; `task/adopt SESSION-ID` makes one a task (its first
  message is the prompt; a worktree session keeps its worktree and merges
  like any task; an idle one waits in `needs-input` with `:outcome adopted`).
- Starting: in a git project (`harness-tasks-worktrees`) `worktree/create`
  on branch `harness-tasks-branch-prefix` + slug + id, then a session in
  that worktree (`harness-tasks-permission-mode`, interactive by
  default) prompted with the task; a system-prompt section tells it to
  commit on its branch and not merge.  Outside git the session runs in CWD.
  A `:main-tree` task skips the worktree: its session runs at the
  project's main root, and the system prompt says the work takes effect
  there, with no branch to make and nothing to merge.  The worktree
  stays locked until its branch is merged; a follow-up to a merged task
  locks it again (see worktree).
- Titles: a task is named as soon as it is submitted, while it may wait
  for a slot: `task/submit` sends its prompt (a backlog task's `:note`)
  to `naming/title` with `:task ID` and the model its session will have,
  and `naming/system-prompt` adds `harness-tasks--naming-instructions`
  (nil for none), so the model titles it like a ticket.  The title
  becomes the task's `:name`; the board, `task_list`, the session list,
  search, notifications and insights show the session's name, else the
  task's `:name`, else the prompt's first line.  The task's session is
  created with `:name` (a backlog task's session, made at once, as it
  starts its work when it has none), so it is not named again.  While
  the request is out, the `naming/auto-p` filter keeps a session of the
  task from being named as its turn starts, and the title names it when
  it comes.  Nothing waits for a title: a failed request (or one that
  times out) leaves the task untitled, and a nameless session of it
  whose turn runs is then named from its first message (`naming/name`
  with `:opening`).  At most `harness-tasks--naming-concurrency` (2)
  requests are out at once, the rest queued; a queued request whose task
  started meanwhile is dropped, as the start of its turn names its
  session.  `task/update` clears `:name` and asks again when the text
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
  false rather than nil), and a board's Review switch turns it off and
  on with `config/set`, globally and saved; tasks already in review wait
  on until verified.
- A turn starting in a task's session makes the task active again, so a
  message sent from a done task's chat buffer reopens it; an archived task
  comes back to the board.
- A task's session does not move to another directory (`session/move`):
  the `session/before-move` filter `harness-tasks--before-move` refuses,
  since the board files the task under its project and follows its work
  in its directory.  A task for the other directory is submitted there.
- `task/list &optional CWD`, `task/get ID`, `task/settings &optional CWD`,
  `task/start ID` (ignores the limit; not while a write-up runs),
  `task/set-priority ID PRIORITY` (low, medium or high, as `task/submit`
  reads it; any task, though it only matters to one still waiting; it
  starts nothing, as no slot frees, and `task/changed` tells the board,
  which reorders *Pending*),
  `task/update ID PROMPT` (not started only; writes a stopped write-up by
  hand; a task named from its prompt is named again), `task/set-all SETTINGS &optional FILTER` (apply `:model',
  `:thinking', `:permission-mode', `:non-interactive' and `:supervisor',
  with an explicit false for the last two meaning off, to every task
  FILTER selects and, when started, its session, and `:priority' to the
  task alone; only the settings given change, so without `:priority' (or
  with null) every task keeps its own, and a bad one is refused before
  any task changes; FILTER is `:columns'
  (default `harness-tasks-bulk-columns': running, pending and blocked),
  `:ids', `:except' and `:cwd' (without it, every project), and review,
  done and archived tasks are never touched; a task already set so is
  skipped, non-interactive counting as what the task would start with
  (`harness-tasks--non-interactive-p`: its own setting, else
  `harness-tasks-non-interactive`, else its directory's
  `harness-non-interactive`), and its session is sent only the
  settings it lacks, so one `session/set-all` changed first gets no
  second hint; a `:supervisor' is the session's `:ext' switch rather
  than a `session/update' setting, so it is applied with
  `supervisor/set' when the module is loaded
  (`harness-tasks--apply-supervisor'), and a backlog write-up's session
  is skipped, its setting waiting for the work; this is the board's bulk
  edit, and the all-sessions
  commands' and `set_non_interactive`'s reach into tasks),
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
  already done emits nothing).  Records are written
  shortly after a change and on exit (`harness-tasks-flush`), each into
  its project's store; a store whose text would not change is skipped.
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

### tasks-search

The task board's search: a query in words ("did I have a task about the
question button?", "restart the errored tasks") finds tasks and may act
on them, answered by a cheap model that returns JSON only.

- `task/search CWD QUERY &optional (:shown IDS)` → promise of
  `(:query QUERY :ids IDS :actions ACTIONS :model MODEL :looked LOOKED)`.
  Nothing changes yet.  IDS are the tasks QUERY is about, best match
  first, archived ones included; ACTIONS are what QUERY orders, each
  `(:task ID :action NAME :text TEXT :title TITLE :confirm BOOL)`, NAME
  one of `harness-tasks-search-actions` (`archive`, `restore`, `stop`,
  `retry`, `start`, `verify`, `complete`, `message`, `reject`,
  `priority`), TEXT the words a message or a send-back carries or the
  priority a `priority` action gives (one naming none, or the task's own,
  or for a done task, is dropped), and `:confirm` t for an action
  that interrupts work, merges it or sends words to an agent (stop,
  verify, complete, message, reject, and archive of a working task),
  false for the rest.  `:shown` is what the board shows now, which
  "them" in QUERY means.  `:looked` says what the model read besides the
  board.
- The message to the model carries a compact dump of the board: for
  every task (newest first, at most `harness-tasks-search--max-tasks`)
  its id, column and state, title, the request it was asked in, its
  priority when it is not medium, the todo it is on, what it waits for
  the user on, the summary it handed in, its branch, times and errors.
  The system prompt
  (`harness-tasks-search--system`) is constant, and the model must
  answer one line of JSON `{"show":[ID…],"do":[{"task":ID,"action":…}]}`.
  Unknown ids are dropped and acted-on tasks are always shown.  When the
  model asks to look further instead of answering -- `{"grep":TEXT}` over
  the sessions' transcript logs (`sessions/*.nodes.jsonl` under the state
  directory, searched in a subprocess) or `{"read":[ID…]}` for the latest
  transcript, at most `harness-tasks-search--read-limit` tasks -- it gets
  one more round (`harness-tasks-search--final-text` closes it) and must
  answer then.
- The model is `harness-tasks-search-model`: `auto` (the default) takes
  the provider of the task model's `cheap` tier (`provider/tier-model`),
  nil uses the task model itself, a string forces one.
  `harness-tasks-search-thinking` (nil) is its thinking level, the
  output budget is `harness-tasks-search--max-tokens`, and a call taking
  longer than `harness-tasks-search--timeout` fails.
  `harness-tasks-search--request` runs it as a side session in
  `task-search/` under the state directory, so the project's Claude
  history and CLAUDE.md stay out of it.  Every search gets its own
  session id, and its process is closed when it ends
  (`provider/close`).
- `task/search-warm CWD` → `(:model MODEL :warm BOOL)`: start the model
  process the next search of CWD's board will use (`provider/warm`), so
  the answer comes sooner; a process left unused is closed after
  `harness-tasks-search--warm-idle` seconds.
- `task/search-apply ACTIONS` → promise of one result per action,
  `(:task :action :title :ok :error :undo)`, run in order: archive stops
  a working task first and archives it once it stopped
  (`harness-tasks-search--stop-wait`), stop never drops a task that has
  not started, retry is `task/retry`, message is a follow-up to the
  task's session (or words added to the prompt of a task with no session
  yet), priority is `task/set-priority` (its result says the priority
  given, as `:text`), and the rest are the tasks methods.  ARCHIVE and
  RESTORE carry `:undo`, the action that undoes them, and PRIORITY the
  priority action back to what the task had.
- Searches are not sessions: their cost is recorded with `usage/record`
  under the board's project with `:session nil`.
- Settings `harness-tasks-search-model`, `harness-tasks-search-thinking`;
  the demo provider answers search requests heuristically (word match
  plus action verbs, and priority words such as "prioritize"), so the
  dev daemon, the tests and the screenshots work offline.

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
  egg brings a new seed) → the VIEW.  `pet/watch CLIENT ON [SESSIONS]`
  → the VIEW: CLIENT, an id the UI makes up, shows the pet now or not;
  with SESSIONS, a list of session ids, it shows the pet only beside
  those sessions (what it says above their chats), not the pet itself.
- It speaks only where it would be seen: about a session while some
  client shows the pet itself or shows it beside that session, about
  nothing in particular (a petting, hatching) only while some client
  shows the pet itself; and only while it is on, not muted, and
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
  most about 3000 characters).  The line is one line, without a leading
  "NAME:" or quotes, at most `harness-pet--max-saying` characters
  (`harness-pet-sanitise`); "..." is silence.
- Every call is `provider/complete` with `:ephemeral t` and `:no-thinking
  t`, a session id of its own (closed with `provider/close` when it
  ends) and `pet/` under the state directory as its directory, so no
  project instructions, memory or history reach it; a call taking
  longer than `harness-pet--timeout` is cancelled.  Its cost is recorded
  with `usage/record` with `:session nil`, under the project of the
  session it spoke about.
- Model: `harness-pet-model`, `auto` (the default) the cheap tier
  (`provider/tier-model`) of the session's model, or of `harness-model`
  for a hatching or a petting; nil that model itself; a string forces
  one.
- Growing: +2 xp for every message the user writes, +1 for every turn
  of theirs that ends well, +3 for every task that gets done
  (`task/done`).  Event `pet/changed VIEW` after any change
  (growing only while watched or when it gains a level), `pet/said
  SAYING` with `(:text :ts :reason :session :session-name)`.  Both are
  forwarded to clients; the methods are `_harness/pet/...` over ACP.
- The demo provider names pets and speaks their lines from a script,
  so the dev daemon and the tests run offline.

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
`harness-supervisor-judge-model`, the provider's cheap tier by default)
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
mode's back.  Deleting a session forgets its judgement.

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
  from the UI, completed tasks' sessions left out by the selection.  A
  sub-agent, a side conversation, a session from before the module and
  one already at the asked value are left alone; each change is the
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
  (`auto`: the provider's cheap tier, else the session's own model),
  `harness-supervisor-tiers`
  (nil: an alist from `mundane`, `standard` or `hard` to a model id),
  `harness-supervisor-thinking` (`((deepseek . "max"))`: an alist from a
  provider id to the level its sessions run at while they supervise),
  `harness-supervisor-worker-thinking` (`((deepseek . "medium"))`: an
  alist from a provider id to the level workers on its models run at),
  and `harness-supervisor-step-budget` (80), in the settings section
  "Supervisor mode".
- Thinking levels.  A session whose provider
  `harness-supervisor-thinking` names has its thinking raised to that
  level while it supervises: `session/ext-changed` on `:supervisor` with
  a true value calls `session/update` `:thinking LEVEL` `:silent t`,
  remembering what it had in `harness-supervisor--raised` (and the level
  it raised it to), and a false or nil value puts the remembered level
  back only while the session still holds the raised one, so a level
  chosen meanwhile stands.  A session whose level was not remembered
  (after a restart) keeps the raised one; deleting a session forgets it.
  This covers a top-level session, a fork that takes its parent's
  setting, a task session (including one `harness-supervisor-tasks` turns
  hands-on right after creation, whose level is put back), and the user
  turning the mode on or off.  `harness-supervisor--provider-thinking`
  reads the alist by `harness-model-provider`.
- Enforcement, in order.  Filter `agent/tools` (90) offers a supervising
  session only an allowlist: the reading tools (`read_file grep glob
  list_dir file_info`, the `session_*` and `task_*` that only look,
  `skill_search skill_load notification_providers`, `emacs_buffers
  emacs_windows emacs_buffer emacs_describe emacs_find_definition
  emacs_messages emacs_open`), `web_fetch web_search`, the coordination
  tools (`ask_user todo_write hand_in notify session_control
  session_send session_move set_non_interactive task_control
  task_submit`), the tool that asks for a directory
  (`harness-perms-dir-tool`) and `harness-supervisor-tools`
  (`no_plan_needed submit_plan retry_step`), plus `bash` when
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
  task_control session_send session_control`); a call is noted from
  `agent/tool-call`, and a result that is an error takes it back out
  (`tools/finished`), since it decided nothing.  The async filter
  `agent/stop` (see agent) answers a supervising session's stop with no
  decision in its turn by `(:stop nil :message REMINDER :from
  (harness-sender-system "supervisor"))`, twice at most in a turn; after
  that the turn ends and the hint "The turn ended without a decision"
  joins the transcript.  Every tool call of a supervising turn is
  counted (`agent/tool-call`; `agent/turn-started` resets it), and when
  the count reaches `harness-supervisor-step-budget`, and every half
  budget after (80, 120, 160…), the session is steered by an
  `agent/prompt` from the same sender to submit its plan: a nudge, never
  a stop.  `no_plan_needed reason` (`reason` required) records the
  decision and a hint "No plan needed: REASON", and does not end the
  turn.  The sync filter `agent/system-prompt` (900) puts
  `harness-supervisor-prompt-section` in place of the Planning section
  (`harness-tools-agent-planning-section`; else at the end), the same
  text on every call, as the prompt is part of the cache.
- Plans are the session's `:ext` `:supervisor-plans`, oldest first, in
  the JSON the store keeps, so they survive a restart; each change of a
  step is `session/ext-changed ID :supervisor-plans PLANS`.  Plan:
  `(:id "p-…" :title :summary :node :call-id :created F :steps (STEP…))`,
  `:node` and `:call-id` being the call that submitted it, which every
  fork step forks the supervisor at.  Step: `(:id :title :prompt :tier
  :reason :context :after (ID…) :model :state :session :attempts N
  :result :error :worker-model :previous)`: `:tier`
  mundane|standard|hard, `:context` fork|fresh, `:state`
  pending|running|done|failed|interrupted|cancelled|superseded,
  `:session` the worker, `:result` its last reply, `:worker-model` the
  model the worker was made for (`retry_step` may change `:model`
  afterwards) and `:previous` the attempt before one that started again,
  `(:attempt N :session SID :model MODEL :error TEXT)`.
  A new plan supersedes the earlier plans' steps that have not started;
  their running steps finish as usual.
- `submit_plan summary steps &optional title`, `steps` being `{id, title,
  prompt, tier, reason, context, after}`, is refused whole, every
  problem named, for an id used twice, an `after` naming no step, a
  cycle, an unknown tier or context or a blank prompt.  Otherwise it
  records the plan, sets the session's plan (`session/set-plan`) to the
  summary, adds a `plan` node and the hint "Plan submitted: N steps",
  starts the ready steps and ends the turn (`:end-turn t`).
  `retry_step step reason &optional plan tier prompt` runs a failed,
  interrupted or cancelled step again on a new worker (`plan` defaults
  to the latest that has the step, `tier` moves it to that tier's model,
  `prompt` adds notes to its prompt) and does not end the turn.  Both are
  kind meta.
- Models.  A step runs on `harness-supervisor-tiers` for its tier, else
  the model of the supervisor's provider that ranks alike
  (`provider/tier-model` cheap, balanced, frontier for mundane,
  standard, hard), else the supervisor's own, with a hint.
- Workers.  A step whose `:after` steps are all done starts: a worker
  session of kind `subagent` named "Step ID: TITLE" is made, with
  `:context-window-limit` from `harness-tools-agent-context-limit`.  A
  fork step forks the supervisor (`session/fork`) at the plan's `:node`
  and `:call-id`, through `seed/fork` when the plan has two or more fork
  steps on the step's model, so that the context is written to that
  model's cache once.  A fresh step is a `session/create` in the
  supervisor's directory, worktree and host, with the supervisor as its
  parent and the supervisor's permission mode, thinking level,
  non-interactive switch and allowed directories; the thinking level is
  the one `harness-supervisor-worker-thinking` names for the provider of
  the worker's own model, else the supervisor's own, and the same
  `:thinking` is passed to a fork so that a raised supervisor level is
  not inherited.  The worker gets one
  `agent/prompt`, from the supervisor session: the `:preamble` of
  `seed/fork`, an opening that tells a fork it is a worker now, the step,
  the attempt before it when the step starts again (below), what the
  steps before it reported (each cut to 2000 characters) and a
  closing.  Workers carry no `:supervisor`: they have every tool.  A
  worker's turn ending `end-turn` or `max-tokens` makes the step done;
  any other end, or no worker, makes it failed.
- A step that starts again (`:attempts` above 1: `retry_step`, perhaps
  on a higher tier, or an interrupted, failed or cancelled step run
  again) decides a fork worker's context by the cache.  A fork never
  shares its parent's cache, a higher tier is a model that never read the
  plan's conversation, and a new fork has no `:cache`, so the cowboy's
  gate never finds it cold: forking the supervisor as a first attempt
  does would send all of it uncached at that model's price.  With
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
  node the fork wrote) or `whole`, and the supervisor a hint naming the
  step, attempt, model and which it was ("Step s2 (attempt 2) on M:
  forked from the warm shared context", "…no warm prompt cache holds the
  plan's conversation, so its worker starts from a brief summary of it
  rather than reading it all uncached", "…and it was not compacted, so
  its worker reads it all uncached").  First attempts and fresh steps
  are unchanged.
- The attempt before.  Before it wipes `:session` and `:error`, a step
  that starts again keeps its worker in `:previous`, when it had one, with
  the model the worker ran on: its session's, else `:worker-model`.  The
  worker's message then has a section "## The previous attempt" after the
  step, naming the attempt, model, session and how it ended, and pointing
  at `session_read` on that session so as not to repeat what failed; for a
  compacted fork the opening adds that the conversation before the message
  was compacted into a summary and `session_history` searches what it
  replaced.
- Reports are messages of the harness's `(harness-sender-system
  "supervisor")` through `agent/prompt`: an idle session starts a turn,
  a running one is steered.  A step done is a hint ("Step ID done on
  MODEL") and starts the steps that waited.  A step that failed, was
  interrupted or was cancelled (its worker session deleted) is a message
  of its own: the step, tier, model and attempt, why, the worker's last
  reply, the steps held on it and those running, and the ways on
  (`retry_step`, a new plan, `ask_user`).  When no step is left but done
  or superseded ones, a message lists each step's result and asks to
  check the work and decide (`hand_in` in a task).  A report that comes
  while the turn that submitted the plan is ending would be lost with
  it, so it is held until `agent/turn-ended`, and queued for the user's
  next message when that turn ended any other way than `end-turn`.
- Filter `agent/outstanding` reports "Supervisor plan: N steps running,
  M waiting, a report to deliver" while steps run, pending steps can
  still start or a report is held; a step held behind one that did not
  get done is not counted, the supervisor having been told.  The tasks
  module keeps the task of the session active, waiting, meanwhile.
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
  compacting a fork (the supervisor, for a step that starts again).
- `seed/list &optional SOURCE-ID` → seeds, newest first, `(:id :source
  :node :model :cache)`, for diagnostics and the UI; kept in memory, so
  one made before a restart is not listed, though its session remains.
- A seed is an ordinary session of kind `subagent`, in the session list
  and readable, deleted with `session/delete`; nothing deletes one.  Its
  forks are children of the seed, not of SOURCE-ID, so whatever is keyed
  on `:parent-id` (the merge queue, say) sees the seed as their parent.
  The supervisor module forks its workers this way.

### tools-fs, tools-shell, tools-ssh, tools-emacs, tools-emacs-eval, tools-web, tools-agent, tools-sessions, tools-notify, tools-handin

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
| `ssh` | SSH | host, command, cwd, timeout | exec (tools-ssh; its path is the directory it runs in on the host, or the host's root when the host expands it: home, a relative cwd) |
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
| `emacs_eval` | Evaluate in Emacs | code | exec (tools-emacs-eval; offered only while `harness-emacs-eval` is on, as it is by default; a judge model must call the code fast first) |
| `web_search` | Web search | query, count | net |
| `web_fetch` | Fetch page | url, max_chars | net |
| `emacs_messages` | Emacs messages | count | read (needs no approval: `harness-perms--inspection-tools`) |
| `ask_user` | Question | question, options (strings, or `{label, diagram}` / `{label, image}` objects: every option has a diagram or none does), allow_free_text | meta (answered with `question/answer SID PID ANSWER`; event `question/asked`; the harness asks its own questions the same way, with no tool call, through `question/ask`) |
| `request_directory_access` | Request access | path, reason | meta (perms module; decided only by the user's answer to a directory prompt, in every mode) |
| `session_info` | Session info | — | read (needs no approval: `harness-perms--inspection-tools`) |
| `plan` | Plan | plan | meta |
| `todo_write` | Todo list | todos | meta |
| `spawn_agent` | Sub-agent | prompt, fork, model, thinking, name, cwd, worktree | meta (runs the child in the background and returns at once; the jail checks `cwd`, as it checks bash's) |
| `skill_search` / `skill_load` | Search skills / Load skill | query / name, file (one of the skill's supporting files) | read (needs no approval: `harness-perms--auto-allow-tools`) |
| `session_list` | List sessions | status, kind, parent_id, name, include_inactive, all_projects, limit | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_search` | Search sessions | query, regexp, all_projects, max_sessions, max_matches | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_read` | Read session | session_id, limit, before, kinds, max_chars | read (needs no approval: `harness-perms--inspection-tools`) |
| `session_history` | Session history | query, regexp, node_id, before, limit, max_chars, kinds, all | read (this session's own conversation from before its last compaction or handoff; needs no approval: `harness-perms--inspection-tools`) |
| `session_send` | Message session | session_id, message, mode (send/queue), wait | meta |
| `session_control` | Control session | session_id, action (cancel/resume/close/rename/answer), name, question_id, answer | meta (answer refuses the harness's cold-cache question, left to the user) |
| `session_move` | Move session | directory, session_id (default: this session), keep_old_directory, reason | meta (the user confirms every call, in every mode; see perms, Confirmations, and `session/move`) |
| `set_non_interactive` | Non-interactive mode | enabled, session_id (default: this session) or all (every current session and task of every project), reason | meta (perms module's away-request stage: turning it on is decided only by the user's answer, in every mode, and denied at once in a non-interactive session; turning it off is allowed at once) |
| `session_wait` | Wait for sessions | session_id / session_ids, until (stopped/idle/blocked/running/changed), mode (all/any), timeout_seconds (optional: wake anyway after this long) | read (registers a wake-up prompt and returns at once; needs no approval: `harness-perms--inspection-tools`) |
| `task_list` | List tasks | column (pending/needs-input/active/review/merging/done), include_archived, all_projects, limit (the most recent) | read (needs no approval: `harness-perms--inspection-tools`) |
| `task_submit` | Submit task | prompt, cwd, model, thinking, refine (for the backlog), main_tree (no worktree: the project's main checkout), priority (low/medium/high: the order waiting tasks start in) | meta |
| `task_control` | Control task | task_id, action (start/message/cancel/merge/verify/reject/complete/archive/restore/delete/priority), message (the feedback, for reject), priority (low/medium/high, for priority) | meta |
| `task_wait` | Wait for tasks | task_id / task_ids, until (settled/done/needs-input/active/review/merging/changed; settled counts review), mode, timeout_seconds | read (needs no approval: `harness-perms--inspection-tools`) |
| `hand_in` | Hand in the finished work | summary, evidence (image/video/file/code/note/tool_call, each with a caption) | meta (task sessions only; needs no approval: `harness-perms--auto-allow-tools`) |
| `open_harness` | Open harness in Emacs | path (default: the session's worktree, else its cwd), focus (for the user: stays until the task is done) | exec (tools-dev; offered in a checkout of the harness only; the instance stops by itself once nothing needs it; needs no approval: `harness-perms--auto-allow-tools`) |
| `notify` | Notification | message, title, urgency (low/normal/critical), providers, url | meta (needs no approval: `harness-perms--auto-allow-tools`) |
| `notification_providers` | Notification providers | (none) | read (needs no approval: `harness-perms--inspection-tools`) |
| `merge_done` | Finish merge | none | meta (merge module) |
| `no_plan_needed` | No plan needed | reason | meta (supervisor module; offered to a session in supervisor mode only; records the turn's decision and does not end the turn) |
| `submit_plan` | Submit plan | summary, steps (`{id, title, prompt, tier, reason, context, after}`), title | meta (supervisor module; supervising sessions only; ends the turn; in Ask mode the user answers its permission prompt) |
| `retry_step` | Retry step | step, reason, plan, tier, prompt | meta (supervisor module; supervising sessions only; does not end the turn) |

The tools of kind read that take a path (`read_file`, `list_dir`,
`glob`, `grep`, `file_info`, `emacs_open`) may read the harness itself
as well as the session's roots: its code and its state directory, its
credentials aside (see perms).  They may read the skills directories
too, and bash reads them in the sandbox (see perms and sandbox).

`hand_in` (tools-handin) is how a task's session finishes: the tool
records the summary and evidence on the task (`task/hand-in'`) and asks
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
snapshot so the view can show it as the link it is.

`open_harness` (`tools-dev`) opens a second Emacs running the harness
from a checkout of this project -- a task's worktree, say -- so harness
changes can be tried live instead of only read.  It runs that
checkout's own live development loop (`scripts/dev.sh start`) with
`HARNESS_DEV_SOCKET=harness-dev-HASH`, a socket derived from the
checkout's true name, so the same worktree reuses its instance and two
worktrees never share one; the instance's state and compiled files stay
in that checkout's `scripts/.dev/state-SOCKET`, passed as
`HARNESS_DEV_STATE` (dev.sh keeps one it inherits, so an instance
opened by the harness of another would share that one's state).  The result lists the
`scripts/dev.sh` commands that drive it (shot, keys, eval, errors,
reload, stop) prefixed with that socket.  `path` defaults to the
session's worktree, else its cwd; a directory that is not a checkout
(`harness.el` and `scripts/dev.sh` side by side) is refused.  The sync
filter `agent/tools` drops the tool outside such checkouts: it is for
this project only.  The bus method `harness-dev/open PATH &optional
FOCUS` does the same for the UI (focus raises the frame); Open harness
in the menu of a task board's review card calls it, and the tool
is in `harness-perms--auto-allow-tools', so the agent needs no approval
to use it.

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
command line is `--daemon=harness-dev-HASH -l
CHECKOUT/scripts/harness-dev.el`) and forgets the records of
instances that no longer run.  It adopts an unrecorded instance whose
checkout is the worktree of one of this harness's tasks or sessions,
or is gone, then checks everything.  Any other instance is someone
else's and stays, and so does the one this harness runs in (its
`daemonp`, or its parent's command line, see
`harness-tools-dev--own-socket`).

Stopping (`harness-tools-dev--stop`) runs `emacsclient -a false -s
SOCKET --eval (kill-emacs)`, from Emacs's own `invocation-directory`,
so nothing of the checkout has to exist.  A daemon still running
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
with the value nil and the session id as its argument.  A handler returns
the plist it was given with its own `sandbox/wrap` options set over it,
such as `(:read-only t :network nil)`, so a later handler's options win
over an earlier one's; a value that is no plist of options signals an
error, so that a faulty handler cannot let a command run with fewer
restrictions than it meant.  The options go to `sandbox/wrap` with the
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
`:parent`, `:name`, `:worktree`, `:branch` and `:result`, kept until the
child is done), so a task whose session's turn ended stays active
(`harness-tasks--on-turn-ended`) instead of going to review while its
sub-agents run.

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
first turn (a step that starts again with no warm seed) starts with far
less than the supervisor holds, so its limit is fitted first: the cap
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
short call a card's is (the `harness-tasks-recap-model' cheap tier, at
most `harness-tasks-recap-max-tokens' tokens) and the same thresholds
`harness-tasks-recap-turns', `harness-tasks-recap-seconds' and
`harness-tasks-recap-tool-calls', measured from the session's start
until the first recap and from the last one after that (FORCE skips
them).  Only a sub-agent's session (`harness-recap--session-own-p')
gets one written; another session's is its card's business, though a
recap already kept for it is shown, and the one in hand is returned
while a new one is made.  `recap/session-done' and
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
host's root, so the first call to a host asks for it, and a grant of
`/ssh:HOST:/` opens the whole host to every tool.  A missing directory
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

The harness asks the user its own questions the way ask_user does, with
no tool call behind them: `question/ask SESSION-ID REQUEST ON-ANSWER`
(tools-agent) puts REQUEST, `(:question :options :allow-free-text .
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
`session_search` greps the `sessions/*.nodes.jsonl` logs in a subprocess,
so transcripts are not loaded into memory to be searched.  A node is one
line of its log and can be megabytes long, so a hit is split from its
file name by a plain search (`harness-grep-hit`, which the task board's
search uses too), never a backtracking regexp that would overflow the
matcher.  Its snippet, a few hundred characters at most, is cut from a
window around the match.  In regexp mode grep decides the hits; a
pattern that overflows the matcher over a whole node is run over pieces
of it just to place the snippet.  `session_send`
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
(`harness-tools-sessions--on-turn-ended`); its optional
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
2. The handler asks a judge model, as the auto-mode permission judge
   is asked: one `:ephemeral` `provider/complete` on the cheap tier of
   the session's model (`provider/tier-model MODEL 'cheap`, else the
   model itself), no tools, no thinking, 200 output tokens and once
   more with 2048 when those ran out, at most 30 s in all.  It reads
   the very code that would run, fenced by a tag of the call's own, and
   rules on performance and blocking only, answering one JSON line
   `{"verdict": "fast"|"slow"|"blocking"|"unsure", "reason": ...}`.
   Only `fast` runs the code, and only when every verdict in the reply
   says so; any other verdict, no verdict, a failed request or a judge
   that takes too long refuses the call with the judge's reason and
   points to the `elisp` tool.  Code longer than 12000 characters, code
   that does not read and a harness with no Emacs lent are refused
   before the judge is asked.
3. The harness sends `eval` (below) with a two-second limit and a
   deadline, and waits five seconds for the answer; an Emacs that has
   not answered by then is reported as not responding, maybe still
   running the code, and the model is told to leave it alone.  The lent
   Emacs evaluates only while its own `harness-emacs-eval` is on, so
   the Emacs that would freeze has the last word.

The result reads as the `elisp` tool's (`=> VALUE`, then the output and
the messages), with `:meta` `(:emacs "user" :verdict V :reason R)`;
code that signals is an error result, and code the lent Emacs stopped
(its time limit, the user's key, C-g) is an error result that says it
ran partway.

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
```

What is sent while a TCP connection connects waits and goes out once
the socket is up, so a client keeps a connection while `harness-acp-open-p`
holds rather than connecting again, which would drop it along with
every request it carries.

RESPOND returns non-nil when the answer went out and nil when it could
not: its connection closed since the request came, or it was answered
already.  A request answered later than it came, such as a permission
prompt waiting for the user, belongs to the connection it came on; the
harness keeps it pending on the session when that connection goes, and
never sends it again on another.  An answer that cannot go out where
the request came goes through the bus method that answers it
(`permission/answer`, `question/answer`).

Wire: JSON-RPC 2.0, one message per line.  Standard ACP methods:
`initialize`, `authenticate`, `session/new {cwd}` → `{sessionId}`,
`session/load {sessionId}` (replays the transcript as updates),
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
pattern, reason}}` (`options`: the same five for every request, named
as the UI's buttons are, `harness-acp-permission-answers`; `cwd`: where
a shell command runs; `paths`: what the call is about, see perms) →
`{outcome:{outcome:"selected",optionId}}`, plus
`_harness:{pattern}` when the client answers a request about a path
outside the allowed directories for another glob pattern than its
`_harness.pattern` (only such a request has one, see perms),
and `_harness/ask_user {sessionId, requestId, question, options, diagrams, cowboy}` → `{answer}`.
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
`harness-tools-agent-image-max-bytes`, 16 MiB).

Extension methods: any bus method whose name starts with `session/`,
`agent/`, `provider/`, `tools/list`, `usage/`, `fallback/`, `worktree/`, `merge/`,
`config/`, `skills/`, `permission/`, `question/`, `compaction/`, `handoff/`, `naming/`,
`project/`, `task/`, `notification/`, `sandbox/status`, `harness-dev/`, `harness/api`,
`harness/modules`, `harness/version`, `harness/reload`, `acp/remote-`, `pet/`, `version/`,
`insights/`, `supervisor/`, `seed/` (`harness-acp-extension-prefixes`), or with one of
`harness-acp-extra-method-prefixes`, which modules of the user's own
add to (see Modules of your own), is callable as `_harness/NAME` with a
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

The bus events of `harness-acp--forwarded-events` and
`harness-acp-extra-events` reach every client as `_harness/event
{event, args}` notifications (the UI runs `harness-ui-event-functions`
with them); among them `session/ext-changed` (a setting a module keeps
on a session changed, each change of a plan's step included) and
`supervisor/changed` (the user switched supervisor mode); see session
and supervisor.

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
client is authenticated.

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
`harness-acp-remote`.  One listener (`harness-acp-remote-host`
0.0.0.0, `harness-acp-remote-port` 4276, binary sockets) reads the
first bytes of each connection: `{` hands it to ACP's line framing
(client kind `remote-tcp`), anything else is an HTTP request.  A
WebSocket upgrade (RFC 6455, implemented in the module: handshake,
streaming frame decoder over a unibyte buffer, ping/pong, close codes
1002/1009) on any path, `/acp` documented, becomes a client of kind
`websocket`; the subprotocol `acp.v1` is chosen when offered, and
`Acp-Connection-Id` is sent, as ACP's draft transport asks.  A text
message may carry several newline-separated JSON-RPC messages.
`GET /pair?code=C` pairs, `GET /` explains; every answer is
`Connection: close`, `Cache-Control: no-store`, `Referrer-Policy:
no-referrer`.

Pairing: `acp/remote-pair` → `(:url "http://ADDR:PORT/pair?code=C"
:ws-url "ws://ADDR:PORT/acp" :address :port :expires :lifetime)` makes
the one code in force (100 random bits, `harness-acp-remote-code-lifetime`).
Opening the link from an address other than this machine's consumes
it and pairs that address (devices `(:id :address :agent :paired
:seen)`, in memory only, dropped after `harness-acp-remote-idle-timeout`
without a connection), answers the waiting `authenticate` requests of
that address and emits `acp/remote-changed`.  Every client the
listener registers carries `:remote (:address A :transport T [:agent
UA :origin O :web BOOL])`; `harness-acp-authorize-functions` lets in a
paired address unless `:web` (an Origin naming a web page, not an
app's own), `harness-acp-auth-methods-functions` offers `pair`, and
`harness-acp-authenticate-functions` answers `authenticate pair` with a
promise settled by the pairing or rejected (-32000) after the code
lifetime.  A bearer token equal to `harness-acp-token` (subprotocol
`bearer.T`, `Authorization: Bearer T`, `?token=T`) authenticates too.

Methods (callable as `_harness/acp/remote-*`): `acp/remote-status` →
`(:running :enabled :corporate :host :port :address :address-set
:addresses ((:address :interface :kind lan|vpn|other) ...) :ws-url
:code-expires :devices (... :connected N) :clients)`,
`acp/remote-start` and `acp/remote-stop` (save `harness-acp-remote`;
stopping drops the clients, the code and every pairing; a policy that
sets `harness-acp-remote` the other way refuses either before anything
listens or stops),
`acp/remote-pair`, `acp/remote-forget-code`, `acp/remote-revoke ID`,
`acp/remote-set-address ADDRESS` (saves `harness-acp-remote-address`,
"" detects; drops the code).  Event `acp/remote-changed (:what
started|stopped|connected|disconnected|paired|revoked|address|corporate
:address A)`, forwarded to UIs.  Corporate mode refuses start and pair,
closes connections as they are accepted, and its change hook stops the
listener.

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
from (`:upstream t`) comes first of its kind: the remote its branch
tracks and the branch it tracks there (`for-each-ref
%(upstream:remotename)`, the remote's URL from `git config`), or
`origin` and the branch its HEAD names on a detached HEAD.  straight.el
and other package managers set that remote to the recipe's repository,
so an install from GitHub is compared with GitHub and one from sourcehut
with sourcehut.  It is named after its host (github, sourcehut, gitlab,
codeberg, bitbucket, else the host, else upstream) and left out when
`harness-version-origins` names its URL on its branch or on none.  It is
read in the harness process, which has no straight.el, and from any
package manager's clone.  Nothing is fetched: the relation (`rev-list
--left-right --count`) and the newest eight commits each side lacks
(`log --no-merges`) are worked out in the first local repository
holding both commits, local checkouts first and the loaded one last,
as package managers clone shallowly.  When none holds both and the
loaded checkout lacks the origin's commit (`cat-file -e`), the harness
lacks it too: the origin is ahead, uncounted.

`version/check (&optional max-age)` → promise of the report `(:checked
:version :running :origins :verdict)`, each origin `(:name :kind
:location :branch :upstream :commit :subject :date :dirty :status
:missing :extra :missing-commits :extra-commits :error)`, `:status`
same, newer, older, diverged, ahead (a commit the harness lacks, no
local repository holding both), unknown (the running commit is in none)
or error, and `:verdict` behind (an origin is newer, diverged or
ahead), unknown (one cannot be placed, or none could be read) or
latest.  The last report answers
while it is about the revision running now and at most MAX-AGE seconds
old; otherwise a check runs, or the one running is joined (replaced
after five minutes).  Checks also run 30 s after the start, 3 s after
`harness/reloaded` and every half hour; each report is announced as
`version/checked REPORT`, forwarded to UIs.  Git always runs
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
(one with a `:pattern`, see perms) shows the glob pattern its answers
hold for on a line of its own (`pattern: ~/notes/**  [Edit] e`), with
`[Edit]`/`e` (`harness-ui-pending-edit-pattern`, also `C-c C-p` in
the chat) to change it in the minibuffer, more or less specific;
`M-n` offers patterns around the request's own
(`harness-ui-pending--pattern-suggestions`: the path itself, its
directory's files of its extension, each directory from the path's up
to the pattern's, the pattern, its parent), and the answer carries
the edited pattern.  Any other prompt is about the call alone and
shows no pattern; `C-c C-p`, or `e` on such a panel, edits the newest
request that has one.  The facts under a panel's title
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
`harness-ui-call` and the chat do not report them, since the harness
goes on with them (a prompt's turn runs, and the redrawn transcript
shows it).  A permission prompt or question shown from before answers
through the bus methods (`permission/answer`, `question/answer`): the
pending module records the connection with each request, and a RESPOND
whose connection is gone would never be heard.  While a chat buffer
fetches its transcript again (after every reload and reconnect) it
holds back node updates, which the fetched nodes carry, but applies
the session record and the activity as they come: a status, queue or
prompt that changed meanwhile is not lost.

Chat buffer (`harness-ui-chat`): transcript region (read-only) + queue
list + attachments row + compose region at the bottom.  Rendering is
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
the language's major mode, lists, quotes, links).  A click or `RET` on
a link opens it (`harness-ui-markdown-open-link`): a URL with
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
`harness-tools-agent-image-max-side` (8000) pixels on a side, telling
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
`harness-chat-panel-functions` (the companion pet's figure goes there
too; a function cannot move point, where its panel goes) and take the
box's message with `harness-chat-send-function`.  A module can draw a
kind of request its own way: `harness-ui-pending-panel-functions` is
tried first for every request record, in the chat and in the popout,
and a function that inserts the panel (decorating it with
`harness-ui-pending-decorate`, the request's id and a keymap) returns
non-nil, so the ordinary panel is not drawn too;
`harness-ui-pending-session` names the session of the buffer drawing.
Cold-cache question (`harness-ui-cowboy`, module `ui-cowboy`): the
harness's question about a cold prompt cache (see cowboy) as a panel of
its own, in the switch banner's amber (`harness-ui-cowboy-face`): a
heading with the clock time the cache lapsed, the model and the
context; who sent the message that waits, with its first line; what
carrying on costs against the cache it lost; a row per choice with its
key, a button, its cost and what it does, the default marked, the
tooltip naming the writer and the context after it; and a footer with
the capitals that answer "always", a line about session_history when
the session has it, and the typed answers.  Its keymap
(`harness-ui-cowboy-keys`: b s t f c q, capitals for "always") has
`harness-ui-pending-question-map` as its parent, so digits pick an
option as on any question; answers go through
`harness-ui-pending-answer-question` (`harness-ui-cowboy-answer`), and
text typed in the box answers it too.  Without a `:cowboy` the ordinary
question panel shows.
Prompt cache warning (`harness-ui-cache`, module `ui-cache`): once the
session's `:cache :expires` has passed while it is idle, closed or
blocked, a panel above the box says so ("Prompt cache expired at
14:07, 5 minutes after its last use") and what the next message costs:
it re-sends ~N tokens (`:usage :context`) uncached, about the
cache-write (else input) price of those tokens instead of their
cache-read price, at the model's list prices, when the catalogue
prices both.  A running session shows none: its request is using the
cache again.  A session switched away from the model whose cache its
requests last used (`:cache :model`) shows the panel at once,
whatever the time ("Prompt cache cold  cached for Opus 4.6, not
DeepSeek V4"), with the same cost: the new model reads nothing of
that cache.  Switched back while the cache lasts, the panel goes; the
new model's first request stamps a cache of its own, and a switch or
compaction that starts the conversation over reports none, so no panel
(see "Session").  While the switch banner (`ui-switch`) asks how to
hand over, or the cold-cache question waits (`harness-ui-cache--asked-p`),
the panel stays away: the banner's options, or the question's, say what
the cache means for each.  The panel needs no input and no polling: each
chat buffer holds one timer, for the moment its cache lapses, which
redraws the box and whatever panel is above it (`harness-compose-redraw`);
a session update (a new request stamps a new `:cache-at`) reschedules
it, and the panel goes as soon as the session runs.  Its text names
clock times only, never "idle for", so nothing in it goes stale between
redraws.  A session without context or cache use never shows it.  Its
last line offers to compact the conversation first, so the next
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
`compacting` meanwhile, so the panel offers nothing then either.  A session blocked on an answer is in the middle of a
turn: its panel offers nothing.
Tools go by their labels everywhere: a tool block's header shows the
label in `harness-tool-title-face` and what the call is about after it
in `harness-tool-subject-face` (the faces stand in for the colon of the
title), a summary block counts the calls by label ("5 tool calls: Read
file ×3, Search files, Find files", then " · thinking ×2" for the
thinking folded in with them), and so do the permission panel,
the activity line and the mode line.  A title recorded before tools had
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
the fold, whose button opens that session.  A call the harness recorded
(`harness-outside-node-p`) opens a turn of its own under its sender's
line, as that sender's message does, rather than joining the agent's
turn or a run of calls, and shows as running until its result comes,
whatever its session is doing.
Auto-scroll follows unless the user scrolled up.  While the session
runs, an activity line under the last block says what the turn does
and for how long: waiting for the model, thinking, writing, preparing a
tool call (with the size of its input so far), running one (with the
last line it reported), checking its permission, or compacting, behind
a spinner.  It is an overlay string redrawn by the spinner's timer, so
it ticks without editing the buffer; a blocked session shows its panel
instead, and the mode line names the phase too.  It has a background of
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
it (through `agent/prompt`).  The header line shows the session's
status, name, model, permission mode, whether it is non-interactive
("non-interactive" in `harness-non-interactive-face`, else a dim
"interactive"), thinking level, context, output tokens, output rate,
cost and [menu]; clicking a setting changes it, and the non-interactive
one toggles.  The output
rate ("48 tok/s", `harness-ui-format-rate`) is the session's rate as the
usage module measured it. It is dimmed when the session is not running,
because it is then the last rate measured. The session has no rate
until it has been measured, and a narrow window drops the rate first.
The UI keeps the rates in a cache (`harness-ui-session-rate`). It is
filled with `_harness/usage/rates` on connect and kept current by
`usage/rate-updated`. Every change runs `harness-ui-rate-functions`,
which redraws the chat headers, the session list and the task board.
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
second at most, as the events come), the session list and the task
boards at most every half second, and only when a figure they show
reads otherwise.
The context figure is a button (`harness-ui-context-limit-map`): in the
chat header it is a segment as the settings beside it are, and in the
session list and on a task card a click acts on the session the figure
shows.  Mouse-1 on it, or `C-c h e` (`harness-set-context-limit`),
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
starts with the state, before the status icon, through
`harness-chat-header-functions`: " supervisor " in
`harness-supervisor-face`, or " hands-on " in `harness-dim-face`, padded
from the window's edge and separated from the status icon as the
header's other segments are.  The segment is fitted at priority 3, below
every segment of the session's own, so a window too narrow for the whole
line drops the badge before it loses the model, the permission mode or
the counts.  A session with no `:supervisor`
(a sub-agent, a side conversation) shows nothing.  A click on the
segment, and `V` in the harness keys (`C-c h V`,
`harness-toggle-supervisor`), toggle the mode: they ask for the opposite
with `_harness/supervisor/set {sessionId, on}` and say what changed
("Supervisor mode on", "Supervisor mode off (hands-on)"), and the header
follows the session as the harness sends it.  The command takes the
buffer's setting target like the other session settings: a session it
refuses when the harness has not sent it or the plugin does not govern
it, and the task board's non-session target -- the setting of the next
task, or of every current task in bulk mode, offered only while the
harness has the supervisor module -- it toggles through
`harness-ui--setting-set' as the board's other setting buttons do; a
harness without the supervisor module
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
`C-a C-k` clears the line), the placeholder, @file and /skill
completion, attachments (`C-c C-a`, pasting `C-y`, drag and
drop), skill expansion (`harness-compose-with-expanded-text`) and ACP
attachment blocks.  `harness-compose-insert` takes `:face`, the box's
background (`harness-compose-face` by default) and `:accent`, the face
of the prompt and of the bar down the box's left edge, through which a
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
Image tokens: an image attached however (`harness-compose--attach`) gets
a `:label`, "image 1", and its token, `[image 1]`, goes into the text
where point is in the box, else at its end (a download's always at the
end, as it lands later), kept apart from the words around it.  The
token is plain text, so it survives redraws, drafts, queueing and
editing a queued item like the rest of the message; an overlay per
token (`harness-compose--show-tokens`) shows it as a chip: a thumbnail
a line high in its `before-string` (an image inside a `display` string
would not draw) and the token as a link in its `display`, which the
command loop's point adjustment makes point step over whole.  After
every command `harness-compose--sync-tokens` makes text and attachments
agree: what is left of a token cut short goes too, an image whose
tokens are all gone is detached and kept in `harness-compose--detached`,
and one kept there whose token is back (undo, yank, typing) comes back
in label order; × deletes an image's tokens with it.  New text
(`harness-compose-set`, `harness-compose-insert` with TEXT) forgets the
kept images.  Numbers never change once given, since a sentence names
them: a new image takes one more than the highest attached, so deleting
the last frees its number and one in the middle leaves a gap, and each
message starts at 1.  Unlabelled images (a draft from before) and other
files take no part.  The attachment lines stay, each image's led by its
token, since they also show files that are no images, downloads in
flight, size, the larger thumbnail and ×.  `harness-compose-attachment-block`
puts the label in the ACP image block's `_harness.label`;
`harness-acp--block-from-acp` makes it the block's `:label`, which
`harness-agent-attachments-to-blocks` keeps for queued messages and
tasks.  `harness-agent--prepare-content` puts a text block of the token
right before each labelled image of a user message for every provider
(Copilot also names the image's blob after it), and
`harness-agent--blocks-text` leaves out the image placeholder of a
labelled image the text names already.  Queued items sent as one
message number their images on across it (`harness-agent--queue-blocks`,
tokens rewritten with them).  The chat styles the tokens of a user
message's labelled images in its text and puts each image's token over
it (`harness-chat--mark-image-tokens`, `harness-chat--blocks-string`).
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
question, on the board or in a popout, carries no attachment: there a
file the text names goes as its reference
(`harness-compose-without-references`).

Quoting to reply: `C-c >` in the box's keymap
(`harness-compose-quote-reply`) puts what a reply answers in the box as
a Markdown quote, its lines after "> ", with point under it, a blank
line apart.  A region over the host's text quotes what it selects as it
shows, read back into Markdown by `harness-ui-markdown-source`, which
undoes the renderer from the faces and properties it left: fenced code
gets its fences back, its language from the label line above the
block, code spans their backticks, links their `[label](url)`, bullets
their `-` and the quote bar its `>`, while invisible text -- a folded
block's body -- is left out.  Only the part of a region above the box
counts, quoted at the box's end; a region within the box turns into a
quote where it is.  Without a region the message at point is quoted
whole, as written, at point in the box or else at its end (the box's
windows follow it there).  Which message that is the host says: text
it marks with a `harness-compose-quote` property, a string, is quoted
as that Markdown (a report's summary carries it, into the chat's review
banner too), and elsewhere the buffer-local
`harness-compose-quote-function` returns it -- the chat's
`harness-chat--quote-at-point` the response, plan or thinking point is
on, else the nearest response or plan above point, so the last one from
the box; a report popout's its summary.

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
BTW overlay keep their own windows.

Fullscreen layout (`harness-fullscreen`, `F` on an overview, `C-c h F`):
an overview -- a view that sets `harness-ui-overview-function`, the
task board and the session list -- takes the left of the frame in a
side window (`harness-ui-fullscreen-width`), and every other window but
one, the slot, makes way for it.  The slot shows the session in sight,
else the one the overview function names (at point, else the most
recent).  While the layout lasts the `fullscreen` position is the
default: sessions and views shown without a position take the slot, and
an overview takes the left.  The layout is kept per frame in a weak
table (`harness-ui--fullscreen-layouts`), with the window configuration
from before it.  `harness-ui-bury` (`C-c C-z` in a chat, where plain
keys type) puts the slot's buffer away and brings back the last buffer
of the user's the slot showed, keeping the layout; `q` on the overview
(`harness-ui-quit-view`) ends it, restoring the configuration, but for
a buffer of the user's left in the slot, which stays in sight.

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
id, or a settings plist with its setter -- and otherwise the current
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
(`harness-ui--handoff-choices-for`).  Its
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
returns non-nil has shown what it is about), else opens its session.
The task board's function opens the board of the notification's
`:project` with point on the task's card, once the board shows it
(within 10 s).  A click on a terminal-notifier notification this Emacs
no longer knows (`harness-notifications-desktop-unknown-click-function`,
set by `harness-ui--init` unless already set) brings a graphical frame
to the front and lists the sessions waiting for the user
(`harness-ui-notify-show-waiting`), else the session list.
`harness-test-notifications` (menu `N`) sends a test
notification through `_harness/notification/send` and says in the
echo area what each provider did with it.

Remote control page (`harness-ui-remote`, `C-c h P`,
`harness-remote-control`): whether the harness serves other devices
(start or stop), the ACP address their clients connect to, the address
of this machine that QR codes carry (chosen among the interfaces), the
pairing QR code and the paired devices (unpair at point).  The QR code
starts folded and unfolds with a fresh code (`acp/remote-pair`); it
folds again once `acp/remote-changed` says a device paired, when its
code expires, and when hidden, which drops the code
(`acp/remote-forget-code`).  It is drawn by `harness-ui-qr`
(`harness-qr-encode TEXT &optional LEVEL MASK` → `(:size :version
:level :mask :modules)`, byte mode, versions 1–40; `harness-qr-image`
one SVG path, black on white; `harness-qr-insert`, half blocks without
images).  In corporate mode the page shows a notice only.

Version page (`harness-ui-version`, `C-c h v`, `harness-version`): the
verdict, the commit running (with, when the harness runs in its own
process, the commit this Emacs loaded the UI from, and a reload button
when the two differ), each origin with its commit and status (the
repository the loaded checkout pulls from says so), the commits the
harness lacks (an origin at the same commit with the same status as one
listed above says so instead of listing them again; an ahead one has
none to list), and what to do: reload when the loaded checkout moved
on, pull into the loaded checkout (`straight-pull-package` under
straight.el) when a remote has newer commits, push when only a local
checkout has them.
Opening it shows the last report at once and asks `version/check` with
a max-age of a minute; `g` asks with 0; `version/checked` redraws it,
and the menu's Version entry says "not the latest" after a report that
found the harness behind.

Task board (`harness-ui-tasks`, `C-c h a`): the project's tasks in six
sections -- requires your input, ready for review, merging, in progress,
pending, completed -- with each card's current todo, progress, elapsed
time, token figures (a working task's context in use and output, growing
as its model streams; a card short of room leaves them out first),
output rate (while its session is open), cost and merge state, one-click answers to a blocked task's
question or
permission, and a compose box that submits a task, edits a pending one,
messages a task's session, answers its question or takes the feedback
that sends a task back from review (`C-g` leaves an edit, message,
answer or feedback for a new task again: a question stays waiting,
never cancelled).  The same box does all of these, so what `C-c C-c`
will do is made plain: a box that sends to an existing session -- a
message, an answer, feedback on a write-up, or feedback that sends a
task back from review -- wears the message colours
(`harness-compose-message-face`, with the prompt and a bar in
`harness-compose-message-accent-face`, carried onto the label line and
the [cancel] beside it), shows the message icon and names where it
sends ("Message to session “X”", "Refine “X” with feedback",
"Answer the session's question “…”", "Send back “X” with feedback");
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
and [Send back], and a box for the feedback.  The header counts the
tasks to review, and `task/review` says in the echo area that one is
ready (`harness-ui-tasks--notify-review`).  The header also says, as a
chat's does for its session, what the board's tasks cost and who pays
(see Cost display below), then the fullest budget that applies to the
project.  The header's Review switch
([Review: on], `V`) turns review off and on again for every project
(`harness-tasks-require-verification`, saved through `config/set`):
off, finished tasks merge and complete by themselves, and Ready for
review shows only while tasks from before still wait there; turning it
off while tasks of the board wait for review offers to verify them.
`config/changed` brings every board the new value.  RET opens the session, and
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
nothing to merge (`harness-ui-tasks-toggle-main-tree`; new tasks only,
never bulk).  While the harness has the supervisor module the line also
shows the supervisor switch (`supervisor`, or `hands-on' once turned
off, `harness-toggle-supervisor'): the setting of the next task's
session, turned for every current task in bulk mode, sent with the
task and applied to its session when it starts.  The harness says
whether it has the module by carrying `:supervisor' in `task/settings';
without it there is no button.  A
Submit / Refine toggle beside that label, showing only the current mode
(a click or `C-c C-t` switches it), picks what a new task does: start,
or go to the backlog, written up by an agent and
waiting in pending until you start it (`s`); `r` refines a queued task,
retries a stopped write-up, writes one up all the same when it refused
the task as a duplicate, or sends feedback on a backlog task's.  A task
whose write-up refused it as a duplicate shows it in Requires your
input, naming the task it duplicates and saying why: `k` drops it, `r`
writes it up anyway, `m` takes what makes it another task than the one
it duplicates.  Beside the Submit / Refine toggle, the priority button
(`medium priority`, `harness-ui-tasks-cycle-new-priority`) cycles the
next task's priority through high and low and back; it is a setting of
the board like the others, sent as `task/submit`'s `:priority`.  Bulk
edit (`B`) turns the setting buttons on every running, pending and
blocked task (`task/set-all` with the one setting a button changes, so
the others stay each task's own), and puts the current tasks' priority
among them: the settings line gains `high priority`, or `mixed
priority` when they differ, in place of the next task's beside the
toggle.  A click reads low, medium or high
(`harness-ui-tasks-bulk-priority`; no answer changes nothing) and sends
`task/set-all` with `:priority` alone; it is the only bulk change that
touches priorities, and the next task keeps its own.  `+` and `-` on a card raise and lower its task's priority
(`harness-ui-tasks-raise-priority` / `-lower-priority`, through
`task/set-priority`; a completed task refuses, as it no longer waits),
and so do the card's menu entries while the task has not started.  A
high task wears `↑` (`harness-icon-task-priority-high`) before its
title and a low one `↓`, and their facts open with "high priority" or
"low priority" (`harness-task-priority-high-face` /
`-low-face`); medium shows nothing.  `I` or
[Add session] makes an ongoing session a task.  A card in Ready for
review whose worktree is itself a checkout of the harness gets Open
harness in its menu (`mouse-3`, `harness-ui-tasks-open-harness`; no
button, the title's click opening the session as on every card): it
starts the worktree's own live development loop in an Emacs of its
own, frame raised, through `harness-dev/open`, so the work can be
tried before it is verified.  That instance stops once the task is
done, archived or deleted (see tools-dev).  `b` or [BTW] (or the
usual BTW command) opens a BTW side conversation over the board about
its tasks (`task/btw`).  `SPC` over a card, or [Answer…] / [Request…]
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
label, the bulk banner, the settings) through
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
Boards reload after any
task, merge, turn, status, worktree, budget or reload event.  New tasks show at
the top of in progress (latest started first), review lists the latest
finished first and completed the latest completed (verified, else
finished) first; merging is the queue's own order, from when each
branch joined it; pending is the queue, in the order its tasks start,
with the backlog among it (highest priority first, then oldest first,
as `harness-tasks--start-order` has it; only queued tasks have a place
in line).

The board's search (`harness-ui-tasks-search`, `/` on the board,
[Search] in its header, `C-c h /` anywhere, which opens the project's
board first) reads a line in the minibuffer and sends it to
`_harness/task/search`; the board then shows only the tasks the answer is
about, archived ones included, under a banner that says the line, how
many tasks it shows and what the model looked at besides the board.
`harness-ui-tasks-filter` carries that: `:show` a predicate over a task,
`:banner` a function returning the text above the columns, `:clear` the
function that drops it, which `C-g` on the board runs when the compose
box has nothing to leave ([Clear] does too).  The columns left without a
task are hidden.  An action the answer does not need confirmed runs at
once, and the banner and the echo area say what it did (the toast), with
[Undo] when it can be undone (archive and restore undo each other, and
a new priority goes back to the old one: "Made “A” high priority");
`task/search-apply` runs them.  An action that interrupts work, merges
it or sends words to an agent is proposed instead: the banner asks, with
a button that does it and [Skip], and `/` then RET on an empty line does
it too (the prompt names what an empty line would do).  The header's
[Search] segment spins while the model works, and each search opens with
`_harness/task/search-warm` so its process is started before the line is
typed; the model's name shows while it answers.  The best match gets
point once the board shows it (`harness-ui-tasks--focus`).

Companion pet (`harness-ui-pet`, `C-c h z`, `harness-pet`, menu `z`):
the buffer `*harness pet*`, and a few places besides.  Before it
hatches: the egg, [Hatch it] (`h`) and what hatching does.  After: a
card with its stars, rarity and species, the creature in its rarity's
colour (`harness-ui-pet-art SPECIES EYE HAT FRAME`, five lines, three
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
(`O`), or [Hatch] and [Turn off], and `g`, `q`.  Turned off (the VIEW's
`:enabled` false), the buffer shows the pet asleep, its eyes shut, and
[Turn it on] (`O` too); both set `harness-pet-enabled` through
`_harness/config/set` with the global scope, as the settings page does.
The places besides, those `harness-ui-pet-places` names (`chat` and
`board` by default), show only while the pet is on and hatched, and
their hooks are set only then (`harness-ui-pet--wire`):

- `chat`: its figure in the bottom right corner of a chat, right above
  the compose box (`harness-chat-panel-functions`), as Claude Code's
  companion sits beside its prompt; not in BTW chats.  The whole
  creature (`harness-ui-pet--sprite`, the art's blank lines and margin
  trimmed, its lines padded to one width) is as many lines as it is
  tall, its name beside its eyes in bold, in its rarity's colour (gold
  when shiny).  What it last said about the session replaces the name: a
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
  point stays where the chat draws).  Every row has
  `harness-pet-figure-face` (fixed pitch) and `default` under its own
  faces, so the chat's panel colour does not show behind it; and as
  nothing is past its lines' ends, where the panel's `:extend` would show
  it, not there either.  How it fits is `harness-ui-pet--fit`, from the
  narrowest and shortest of the windows showing the buffer.  A window
  narrower than `harness-ui-pet--whole-columns` (40) or shorter than
  `harness-ui-pet--min-lines` (20) gets the pet's face on one line
  instead (`harness-ui-pet--face-row`), with its name, or the first of
  its words in quotes (`harness-ui-pet--quip-width`, 28 columns, cut at
  a space), as Claude Code's narrow terminals do.  So does every window
  with `harness-ui-pet-figure` set to `face`.  Only a window too narrow
  for even the face goes without.  Words show until the session's next
  `agent/turn-started` or for `harness-ui-pet--saying-lifetime` (15
  minutes), and not while the pet is muted.  Hovering over the creature
  names it, a click shows the buffer.
- `board`: the same figure in the task board's bottom right corner, from
  `harness-ui-tasks-corner-functions` (`harness-ui-pet--board-corner`),
  with what it said last about anything.  Its bottom rows end the first
  lines above the compose box, those that leave it room (the label, then
  the settings), as many as save lines.  So the creature takes only the
  lines it is taller than they are, and its bubble goes beside its upper
  rows.  The rows on the board's lines have `harness-pet-figure-face`
  alone, so the band of a box that messages a session shows through.
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
`harness-pet-` option.  Each chat and board notes what its figure shows
(`harness-ui-pet--panel-shown`: the look, the words, the fit and the
pixels of a column), and `harness-ui-pet--sync-panels` draws it again
only where that would change -- a chat's tail through
`harness-compose-redraw-function` once the chat has drawn its compose
box, a board's tail lines through `harness-ui-tasks-redraw-tail-lines`
-- after `pet/changed` (what it says comes with one),
`agent/turn-started` and a change of places, and, 0.1 s after things
settle, as windows change size (`window-size-change-functions`, while it
sits in chats; a board fits its tail itself), buffer
(`window-buffer-change-functions`) or text scale (`text-scale-mode-hook`).
A buffer no window shows is drawn again only when what its figure shows
changes, not for want of room: the window that shows it next fits it.
No timer runs for it otherwise.  This Emacs tells the harness where the
pet is on screen (`_harness/pet/watch`, client `HOST:PID`) whenever that
changes.  It is t while the buffer is on screen, or a board while the
pet sits on boards.  With `chat`, it is otherwise the ids of the
sessions whose chats are on screen, so the pet speaks about those
sessions only.  It is sent from `window-buffer-change-functions` while
the buffer lives or the pet sits in chats or on boards, as the buffer is
killed, and after every connect.  Animations -- the egg wobbling then cracking
and sparkles as it hatches, hearts as it is petted, a fidget as it
speaks (after the sparkles, when its first words come while it
hatches) -- are a few frames each on one timer that stops with the
last frame or as soon as the buffer is off screen, so nothing runs
while nothing happens; `harness-ui-pet-animations` nil keeps it still.

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
outlasts the counts and most buttons, its budget making room first.
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

Other buffers: settings page (`harness-ui-config`, above), sessions list (`tabulated-list-mode`, tree indentation for
children, filter/sort by any column; the Context and Output columns show
each session's token figures, which grow while it streams; a Tok/s column shows each session's
output rate, dimmed while it is not running; SPC on a session pops out what it
waits on (a session that waits on nothing leaves SPC scrolling), its
status cell's tooltip says so (`harness-ui-sessions-requests`);
scoped to the current project, its
git worktrees and so its tasks' sessions included, each session's root
resolved to its main checkout once with `harness-files-owning-checkout`;
a task's session is of kind task and goes by its task's title, as on the
board, until the model names it after its first turn — the list loads
the tasks with `_harness/task/list` and follows `task/changed' and
`task/deleted'),
conversation tree (`harness-ui-tree`), usage dashboard (`harness-ui-usage`,
svg charts via svg.el; by project, the rows of a project's git
worktrees, its tasks' and sub-agents', fold by their `:main` into one
line with their sum and count, folded until TAB, RET or a click unfolds
it, `w` or `[show worktrees]` every project, the main checkout's own
usage first, then each worktree's; a redraw keeps every window's start
and point lines), Insights report (`harness-ui-insights`:
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
(`harness-ui-notify`: global mode-line segment with blocked/running/idle
counts, clickable), BTW side window (`harness-ui-btw`: a new, empty
session listed under the session it is opened over but sharing nothing
with it or with other BTWs (`session/btw`), or, over a view that sets
`harness-ui-btw-start-function`, a new conversation the view starts, shown
in the session's own chat buffer with point in its compose box, so the
question is written and sent like any message; nothing is read in the
minibuffer.  The buffer is the full chat: its header line (model,
permission mode, non-interactive, thinking, context, output tokens, output rate, cost, [menu]),
keys and menu are a session's, `harness-ui-btw-minor-mode` only adding a BTW segment in
front of the header through `harness-chat-header-functions` (what it
is about, [close], [keep]) and `C-c C-k`/`C-c C-o` to close and keep
it; one over a session starts in that session's permission mode, and
every one at the BTW thinking level (`harness-btw-thinking`).  The
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
quit; `harness-ui-popout-at-point-functions' lets a view pop out the item
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
nothing merged recently shows no panel); the session's box sends
as always and the harness takes any message the user sends the task's
session for the feedback that sends it back (`harness-tasks--on-message'), so
[Send back] only points at the box, while
`harness-ui-report-compose-functions` gives the report box's text to
`task/reject` as the feedback; `harness-ui-review-minor-mode` puts
those two keys over the buffer's own, only for as long as it shows; it
follows the task events of its session and draws again only when what
it shows changes, finding the chat buffer by session id with `equal`,
since an id from the harness process is a fresh string), the switch
banner of a session (`harness-ui-switch`: the chat panel that asks how
to hand the conversation over when a lossy model switch needs it -- the
models, the reason, the risks and costs as labelled rows, and a button
and a key per way to hand over, falling back to the minibuffer question
when no chat buffer shows; see "Switching model or provider"), the
prompt cache warning of a session (`harness-ui-cache`: the chat panel
that says the cache lapsed and what the next message re-sends, drawn
by a timer at the moment it lapses, with buttons that compact the
conversation first; see "Chat buffer"), the cold-cache question
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

The review of a task's changes (`harness-ui-patch-review`, module
`ui-patch-review`) keeps to itself, so that it could become a package of
its own: nothing else names it
(`harness-ui-patch-review-is-unknown-to-the-rest` checks), and its
module's shutdown takes it out again.  It is a panel of the report: on
`harness-ui-report-panel-functions` at depth -10, before the review
banner, it returns the changes of a task in review that has a branch,
and nothing for any other task.  The panel is drawn in the popout
buffer, so it knows the report it is in; a report opened anew, a popout
buffer it has not drawn in yet, reads the branch again.  Its rows carry
a keymap of their own as a text property, which the popout puts before
its own keys.  The comments go into the box the review module gives the
report (`harness-ui-report-compose-functions`), written between the
box's markers (`harness-compose-start` and `harness-compose-end`) with
the buffer narrowed to them, and C-c C-c sends the box as the review's
feedback, as it sends any: the module adds no sending of its own.  A
hook on the popout's `after-change-functions` counts the comments in the
box again once the typing stops, and draws the report again when the
counts changed; while the report draws, the panel reads the box with
`harness-compose-text`, which gives the text the popout captured before
it erased the buffer.

The changes show for a task whose project, else its worktree, is a local
directory, when the harness is not remote
(`harness-ui-connection-address`); else the panel says why.  Git runs in
the Emacs that shows the UI, with `GIT_OPTIONAL_LOCKS=0`, so that it
takes no lock the task's own git could trip on.  `git merge-base` of the
branch with the task's `:base` (HEAD when that is blank or gone) gives
the commit compared with; `git diff --raw -z -M --no-abbrev` and the
patch between the two give the files and their hunks, paired by path,
and `git status` in the worktree tells the panel to say when it has
changes not committed.  A file is seen by its path and its blob on the
branch, so one the branch changed again is not.  RET runs
`ediff-buffers` on the two blobs, laid out by
`harness-ui-patch-review-ediff-window-setup`, once it saved the frame's
window configuration and deleted every other window, the report's side
window too (`ignore-window-parameters`): Ediff's own setup deletes the
other windows, which it cannot do from a side window.  q sets the
configuration back.  The report, drawn again meanwhile, gets its window
start and point anew, since its markers in the configuration went with
the text they were in, and a window whose buffer was killed -- the
report's, when the task was decided while Ediff showed -- goes
(`window-restore-killed-buffer-windows`).  N and P read the next file's
blobs, then end the Ediff under way quietly, within
`save-window-excursion`, and start the next in its place, keeping the
configuration to give back.  The control panel's map is a child of
Ediff's with c, N, P and q (under evil, `evil-normalize-keymaps` puts it
where evil-collection made Ediff's map overriding) and a brief help of
its own (`ediff-brief-help-message-function`); quitting goes through
`ediff-really-quit` with `ediff-keep-variants` bound, so it asks
nothing, and the review kills the two versions itself.

c puts a comment on the last line of the current difference on the
branch (at the merge base for a difference that only deletes) in the
box, filled to `harness-ui-patch-review-fill-column`.  The box reads
back as the quote it holds: a line starting with ">" quotes the diff, a
`diff --git` line opens a file, a hunk's header sets the line numbers,
which go on across the comments, and a paragraph of other lines is a
comment.  A comment goes under the line it is about when the box quotes
it already, after the comments there.  Else it quotes that line, the
change it ends and at most `harness-ui-patch-review-context-lines` lines
before it -- not from the middle of another change -- under a hunk
header that counts just those lines, with git's heading; when the box
quotes some of them already, the quote goes on after the last of those
instead, with no header.  A line the diff does not have gets the nearest
one, the comment saying which line it means, and a comment with no
difference current is on the file as a whole, under its `diff --git`
line.  The files keep the diff's order in the box, and a file's hunks
the order of their lines; the first quote gets a line before it naming
the branch, its tip, the base and the merge base.  A report closed
meanwhile opens again out of sight for its box, its draft restored.  The
module follows `task/changed`, `task/review` -- a task back for review
has its branch read again -- and `task/done` and `task/deleted`, which
drop the review: at once when its Ediff does not show, else when q
leaves it.
