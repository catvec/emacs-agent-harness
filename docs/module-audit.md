# Module and API audit

An inventory of the harness's modules and of the ways they meet, made
in October 2026 with the module pages (docs/modules, written by
`scripts/module-docs.sh` from the modules' source; see "Pages of the
modules" in docs/architecture.md). Its question is whether the harness
stays one set of small parts with few, clear seams, or turns into a
tangle where every feature hooks into ten places.

The audit kept to three rules: no renames of public API, no
restructuring of module files, and no changes to module boundaries.
Mechanical fixes were made with it (below); larger items are listed
as follow-ups. Review then asked for two changes past those rules,
made too: the agent tools became a module each, and the two UI halves
named otherwise were named after their modules.

## What there is

| | |
|---|---|
| Modules | 86: 55 in the harness process, 31 in the UI |
| Core modules (`harness-core-modules`, with what they bring) | 35: 25 in the process, 10 in the UI |
| Methods (`harness-defmethod`, `harness-register-method`) | 240 |
| Events | 92 declared, 92 emitted; 45 handled on the bus by name |
| Filter chains | 18 |
| Hooks the harness defines | 38 |
| Tools | 50 |
| Model providers defined by name | 3 (`claude`, `copilot`, `demo`); OpenAI-compatible, DeepSeek and Bedrock endpoints define theirs as they are configured |
| Bus subscriptions | 116, none of them a lambda |
| Filter chain joins | 47 |
| Hook additions | 130; the 2 lambdas are buffer-local (`ui-acp-remote`, `ui-patch-review`) |

Modules meet in five ways, and each has one job:

- **Methods** (`harness-defmethod`, `harness-call`): a module asks
  another for something, by name, and gets an answer or a promise.
  Over ACP they are `_harness/AREA/VERB`, so the UI and remote clients
  call the same ones.
- **Events** (`harness-declare-event`, `harness-emit`, `harness-on`):
  a module says what happened; any number of others react. The UI
  hears those `harness-acp--forwarded-events` lists.
- **Filter chains** (`harness-run-filter`, `harness-add-filter`): a
  module lets others change or veto a value it is about to use, in
  priority order (permission decisions, the system prompt, a turn
  about to start).
- **Hooks**: Emacs hooks, mostly in the UI (redraws, buffer
  lifecycles, `harness-ui-event-functions`).
- **Requiring another module's file**: calling its functions directly,
  which makes the two one unit in practice.

## Fixed with this audit

- **Reload.** `harness-reload` loads new code but did not run a ready
  module's `:init` again, so a handler that new code added there was
  never registered, and 15 modules carried a top-level `(when
  (harness-module-ready-p 'NAME) ...)` block repeating their
  registrations by hand for reloads. Now `:init` runs again at every
  reload (`harness-module-start`), `harness-on` and
  `harness-add-filter` add a named handler once (moving it when its
  priority changed), and the 15 blocks are gone, their registrations
  in `:init`. The modules with work to do once per start (reading
  state, recovering, connecting: acp, fallback, session, supervisor,
  tasks, usage, ui and ui-notify) check `harness-module-ready-p` first,
  and what the blocks did only at a reload (naming the sessions and
  tasks left without a name) is done in `:init` when the module is
  ready already.
  The contract is in `harness-define-module`'s docstring and in
  docs/architecture.md, Reload safety.
- **Events never declared.** `harness/started`, `harness/stopping` and
  `harness/reloaded` were emitted by harness.el and handled by modules
  but declared nowhere, so no page listed them. They are declared now.
- **An event the UI could never hear.** ui-usage listened for
  `usage/recorded`, which is not forwarded to the UI, so the branch was
  dead (the end of the turn that recorded the usage already tells it).
  It is gone.
- **What a module brings along.** A module that requires another's
  file loads it, whatever its `:requires` says; that requirement was
  invisible. The pages now list it under "Brings along", and the
  loader's selection follows it, so enabling a module loads, compiled,
  every module and library its file needs.
- **A bare default.** Every module used to load. Now the core loads,
  and the rest is enabled Doom style (`harness-enable-modules`, `M-x
  harness-enable-module`), with every optional module documented in the
  template of docs/modules/README.md. The core is what a session needs
  to work: besides the turn loop, the providers' base and the file,
  shell and Emacs tools, it has session names (`naming`), worktrees
  (`worktree`, with its list `ui-worktree`) and the agent tools.
- **The agent tools, a module each.** tools-agent held five tools that
  have little to do with each other. Now `tools-question` is ask_user
  and the questions the harness asks itself (`question/ask`),
  `tools-plan` the plan tool, `tools-todo` todo_write,
  `tools-session-info` session_info, and `tools-agent` keeps
  spawn_agent and the Planning section of the system prompt. All five
  are in the core; `harness-disabled-modules` leaves out any of them.
  The moved functions and variables carry their new module's prefix
  (`harness-tools-question-image-max-bytes` was
  `harness-tools-agent-image-max-bytes`).
- **Halves named as halves.** The loader pairs `NAME` with `ui-NAME`,
  but `acp-remote`'s page was `ui-remote` and `handoff`'s banner
  `ui-switch`, so each half had to be enabled by itself. They are
  `ui-acp-remote` and `ui-handoff` now, and come with their modules.
  The remote page's commands, mode, keymap and buffer-name option keep
  their old names as obsolete aliases.

## Findings and follow-ups

### Requirements a module's file has but its `:requires` does not

14 modules require another module's file at top level without naming
it in `:requires`, so the start order relies on load order:

| Module | Its file requires | `:requires` |
|---|---|---|
| merge | tools | session agent |
| tasks | priority | store project session agent |
| tasks-search | priority | tasks provider |
| tool-slots | priority | tools |
| tools-agent | priority | tools session agent |
| tools-sessions | priority | tools session agent |
| ui-btw | ui-compose | ui |
| ui-cache | ui-compact | ui ui-chat |
| ui-chat | acp ui-compose ui-pending | ui |
| ui-patch-review | ui-compose ui-popout | ui ui-report ui-review |
| ui-pending | acp | ui ui-compose |
| ui-sessions | ui-pending ui-priority | ui |
| ui-tasks | ui-compose ui-pending ui-priority | ui |
| ui-tasks-search | ui ui-compose | ui-tasks |

Follow-up: name them in `:requires`. `priority` is required by six
modules for its vocabulary alone, so it could become a library of
lisp/ like harness-files.el instead.

### Presence checks for what a module requires

25 modules check `harness-method-exists-p` for a method of a module in
their own `:requires`, which is always there once they start:

agent, compaction, config, cowboy, fallback, handoff, insights, merge,
naming, perms, pet, provider-claude, recap, sandbox, seed, session,
supervisor, tasks, tasks-notify, tasks-search, tools-agent,
tools-handin, tools-notify, tools-sessions, usage.

The checks are harmless but suggest a dependency is optional when it
is not, and hide which ones really are. Follow-up: drop them, so that
a check marks an optional dependency (the pages then show it as "when
it is loaded").

### Optional dependencies are implicit

Many modules use others when they load and work without them: tasks
gives each task a worktree (`worktree`, in the core) only when `merge`
can merge it back, and reads its sessions' `hand_in` reports from
`tools-handin`; without `merge` tasks work in the main tree. Nothing
declares that, so the enabling template cannot suggest them, and the
task prompt tells a session to finish with `hand_in` whether
`tools-handin` is loaded or not. Follow-up: a `:suggests` keyword on
`harness-define-module` for the template, `harness-enable-module` and
the pages to read; and a hand-in instruction that depends on the tool.

The same goes for the Planning section tools-agent adds to the system
prompt: it names the plan and todo_write tools (core modules of their
own, which `harness-disabled-modules` can leave out) and the merge
queue, which is not in the core. A sub-agent's worktree is made
without `merge` all the same, and its report says then that nothing
merges the branch back. Follow-up: build the section from the tools
and methods the session has, and let the supervisor find it by its
heading rather than by its text (it replaces it with its own).

### The UI's events

- Every event the UI receives goes through each of the 16 functions on
  `harness-ui-event-functions`, each comparing its name with strings.
- An event reaches the UI only if acp's `harness-acp--forwarded-events`
  lists it (or `harness-acp-extra-events`, for a module of your own),
  so a module whose UI wants a new event edits acp too.

Follow-up: a UI-side registry by event name (`harness-ui-on`), as the
bus has; and a `:forward` flag on `harness-declare-event` in place of
the central list. Then a feature declares its events where it emits
them, and its UI subscribes to them by name, and nothing else changes.

### Shutdown mirrors `:init` by hand

A module's `:shutdown` removes, one by one, what its `:init` added, and
nothing checks that the two match. Follow-up: record the handles
`harness-on`, `harness-add-filter` and `add-hook` return while a
module's `:init` runs, and remove them all when it stops.

### Registrations outside `:init`

A few registrations are made as the file loads rather than in `:init`:
the step counters and watched events of harness-tools.el,
`harness-describe-modules-functions` in harness-ui.el, a pending-change
hook of harness-ui-pending.el, and two hooks of harness-ui-tasks.el.
Named and so reload-safe, they are made whether the module starts or
not, and stay after it stops. Follow-up: move them into `:init`.

### Where integration concentrates

The modules with the most handlers, filter joins and hook additions:

| Module | Total | Bus handlers | Filter joins | Hooks |
|---|---|---|---|---|
| tasks | 20 | 10 | 9 | 1 |
| supervisor | 16 | 9 | 7 | 0 |
| tools | 16 | 16 | 0 | 0 |
| usage | 16 | 15 | 1 | 0 |
| ui-chat | 14 | 0 | 0 | 14 |
| perms | 13 | 5 | 8 | 0 |
| ui-compose | 13 | 0 | 0 | 13 |
| acp | 12 | 11 | 0 | 1 |
| tools-sessions | 12 | 10 | 2 | 0 |
| ui-tasks | 10 | 0 | 0 | 10 |

The hooks most added to: `harness-ui-event-functions` (16),
`harness-ui-redraw-hook` (13), `kill-buffer-hook` (7),
`kill-emacs-hook` (5), `post-command-hook` (4), and
`harness-chat-mode-hook`, `harness-chat-panel-functions`,
`harness-ui-connected-hook` and `harness-ui-sessions-changed-hook` (4
each). tasks and supervisor cut across sessions by design; the others
are what to watch as features are added. A handler on
`post-command-hook` runs at every key, so each of those must stay
cheap.

### Methods of the client

`client/notify` and `client/customize-save` are called by
notifications, ui and harness-util.el and defined by the ACP client,
not by a module, so the pages name no owner for them. Follow-up:
declare the client's methods where the pages can read them.

## Keeping it tidy

The conventions the pages rely on are in docs/architecture.md (Pages
of the modules). In short: a module declares the events it emits,
registers named handlers in `:init`, names in `:requires` every module
whose functions it calls, checks for a method only when the module is
optional, and says in its Commentary how it works. Run
`scripts/module-docs.sh` after a change; a page that grows a long
"Uses" section is a seam worth a second look.
