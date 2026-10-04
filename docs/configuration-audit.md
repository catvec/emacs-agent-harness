# Configuration audit

The harness exposed 186 `defcustom`s: every knob of every module, all
equally visible, all documented the same way.  That is too many for
anyone to explore, and most of them were not choices a person makes.
This audit asked three questions of every option, and this document is
the answer: what duplicates what, what should never have been an option,
and how the ones worth keeping are now presented.

The changes are in this repository; this file is the record of them, so
the next option has somewhere to be judged against.

## The rule

An option earns its place only when two people could reasonably disagree
about it, in a way the harness cannot decide.  Following the driving
analogy: the driver chooses speed, braking and direction; nobody
configures the length of the steering rod.  Applied to the harness:

| Tier | What it is | How it looks | Where it shows |
|---|---|---|---|
| **Primary** | A workflow choice, by user story: model, permission mode, task board defaults, notifications | global `defcustom`, most also layered through `.dir-locals.el` | On the settings page at the top, grouped in sections |
| **Advanced** | Rarely wanted, but real: a CLI path, a provider catalogue, a branch namespace, log level | global `defcustom`, `harness` group | On the settings page folded under *Advanced*, one click away, still listed by Customize |
| **Internal** | A design decision of the implementation: prompts, timeouts, debounce and poll intervals, per-tool caps, retry counts, metadata tables | `defconst`/`defvar` named `MODULE--thing` | Not an option at all; settable from an init file or `harness-server-init-file` if someone insists |

Three further rules, learned from the duplicates below:

- **One mechanism, one option.**  When two modules each need "the git
  program" or "seconds before forcing a cancel", that is the same
  setting.  It lives in one place, or it is a constant.
- **One feature, one entry point, parameters inside.**  Two options that
  do the same thing with a different constant (`harness-worktree-branch-prefix`
  in the module and again in its UI) are one option.
- **A knob nobody asked for is a compatibility promise you did not mean
  to make.**  Every `defcustom` is an interface; changing a constant is
  refactoring, changing an option is a breaking change.

Faces are deliberately out of scope.  Emacs users expect `M-x
customize-face` and themes to restyle them, and a face cannot break an
implementation the way an option can.  The interface's own options
(`harness-ui-*`, `harness-chat-*`, 11 of them) are likewise left alone:
they live in this Emacs, not in the harness process, and now have a
button on the settings page (*Customize the interface*) rather than
being mixed into the harness's settings.

## Result

| | Before | After |
|---|---|---|
| `defcustom`s in the harness | 186 | 75 |
| Primary options, in sections | – | 26 |
| Advanced options on the settings page | – | 26 (plus 12 hidden startup options, below) |
| Interface options (`harness-ui-*`, `harness-chat-*`) | 11 | 11, in Customize |
| Internalised as `MODULE--constant` | – | 104 |
| Merged into an existing option, or removed | – | 7 |

No functionality was removed: an internal constant still holds the same
value and can still be set in an init file, or in
`harness-server-init-file` for the harness process.  It is simply no
longer advertised as an interface.

The 12 options that decide how the harness starts and talks to the UI
(`harness-process`, `harness-state-directory`, the module lists, the
`harness-server-*` and `harness-acp-*` options) stay as they were:
global, `defcustom`, and deliberately absent from the settings page,
because a running harness cannot change them under itself.  They are a
different kind of "advanced": read at startup, from the init file.

## Duplicates: what, and why

These are options that meant the same thing twice.  The cause in almost
every case is the module boundary: modules were developed in parallel
and each one declared the knob it needed, with its own prefix, rather
than a shared setting or a constant.

| Duplicate group | Why it happened | What changed |
|---|---|---|
| `harness-default-model` and `harness-model` | The provider module wanted a default that works with no config module loaded, so it declared its own; the config module declared the user-facing one | `harness-default-model` is now an obsolete alias of `harness-model` (declared before it, so a value set under the old name still wins). Both were `"claude:claude-fable-5-1"`. |
| `harness-merge-git-program`, `harness-tasks-git-program`, `harness-worktree-git-program` | Three modules, each shelling out to git, each with its own copy | Removed. The git program is `"git"`; there is one PATH |
| `harness-provider-claude-interrupt-timeout`, `harness-provider-copilot-interrupt-timeout`, `harness-agent-cancel-grace` | Each provider CLI needs a grace period before SIGKILL; the agent has its own too | Internal constants. They are properties of each CLI's protocol, not of the user |
| `harness-bedrock-request-timeout`, `harness-openai-request-timeout`, `harness-http-default-timeout` | Three layers each defaulted the same transport timeout | Internal constants; `harness-http--default-timeout` is the one that applies |
| `harness-provider-claude-progress-interval`, `harness-provider-copilot-progress-interval` (and openai) | Same idea, once per provider | Internal constants |
| `harness-provider-claude-quota-ttl`, `harness-provider-copilot-quota-ttl` | Cache freshness of a quota report, per provider | Internal constants |
| `harness-openai-models-ttl`, `harness-bedrock-models-ttl` | Model catalogue cache, per provider | Internal constants |
| `harness-bedrock-max-tokens`, `harness-bedrock-prompt-caching` and the per-endpoint `:max-tokens`, `:prompt-caching` | The global was the default for the endpoint key: two spellings of one decision | The global is an internal constant default; the endpoint keys remain the one way to choose per endpoint |
| `harness-debug-backtraces`, `harness-log-level` | Two switches for one mechanism: verbose diagnostics | `harness-log-level` at `debug` now logs the backtraces; the second option is gone |
| `harness-worktree-subdirectory`, `harness-worktree-directory-function` | A default layout and the function that overrides it | The function stays (it returns the full path); the subdirectory is the internal default it uses |
| `harness-worktree-branch-prefix`, `harness-ui-worktree-branch-prefix` | The UI kept a copy of the module's default to propose a branch | The UI asks for a branch and lets the harness name it with the module's prefix when the answer is empty |
| `harness-sandbox-policy`, `harness-sandbox-backend` (`none`) | Policy `off` and backend `none` both mean "do not sandbox" | Kept: policy is *whether*, backend is *which*. `none` is documented as subject to the policy, and is advanced |
| `harness-perms-auto-allow-tools`, `harness-perms-rules` | A built-in allow list and a user rule list that can express the same thing | Kept, but the allow list is now `harness-perms--auto-allow-tools` (an internal constant); a user who wants allow rules writes `harness-perms-rules`, the one user-facing mechanism |
| `harness-tasks-notify-providers`, `harness-notifications-providers` | Per-feature override of where notifications go | Kept as advanced: it is a real "send task notifications elsewhere" choice, and defaults to the generic setting |
| `harness-context-reserve` and `harness-compaction-max-tokens` | How much room to leave before compacting, and how big the summary may be | Internal constants of the compaction design: a reserve smaller than the summary budget breaks compaction, so they are one decision, not two knobs |

## Options that are no longer options

104 options moved from `defcustom` to an internal `MODULE--constant`.
The value and the docstring are unchanged; only the name and the
visibility are.  The naming convention already existed in every module
(`harness-tasks--merge-attempts` next to `harness-tasks-*`): the audit
simply pushed the implementation detail across that line.

| Old option | Constant |
|---|---|
| `harness-tools-emacs-value-chars` | `harness-tools-emacs--value-chars` |
| `harness-tools-emacs-messages-default` | `harness-tools-emacs--messages-default` |
| `harness-elisp-timeout` | `harness-elisp--timeout` |
| `harness-elisp-max-value-chars` | `harness-elisp--max-value-chars` |
| `harness-log-max-lines` | `harness--log-max-lines` |
| `harness-files-timeout` | `harness-files--timeout` |
| `harness-http-curl-program` | `harness-http--curl-program` |
| `harness-http-default-timeout` | `harness-http--default-timeout` |
| `harness-notifications-desktop-app-name` | `harness-notifications-desktop--app-name` |
| `harness-acp-server-enabled` | `harness-acp--server-enabled` |
| `harness-acp-session-debounce` | `harness-acp--session-debounce` |
| `harness-agent-base-system-prompt` | `harness-agent--base-system-prompt` |
| `harness-agent-cancel-grace` | `harness-agent--cancel-grace` |
| `harness-agent-progress-interval` | `harness-agent--progress-interval` |
| `harness-compaction-system-prompt` | `harness-compaction--system-prompt` |
| `harness-compaction-request-text` | `harness-compaction--request-text` |
| `harness-compaction-max-tokens` | `harness-compaction--max-tokens` |
| `harness-compaction-levels` | `harness-compaction--levels` |
| `harness-merge-hold-timeout` | `harness-merge--hold-timeout` |
| `harness-naming-max-length` | `harness-naming--max-length` |
| `harness-naming-system-prompt` | `harness-naming--base-system-prompt` |
| `harness-naming-request-text` | `harness-naming--request-text` |
| `harness-notifications-timeout` | `harness-notifications--timeout` |
| `harness-notifications-max-body` | `harness-notifications--max-body` |
| `harness-gotify-priorities` | `harness-notifications--gotify-priorities` |
| `harness-perms-auto-allow-tools` | `harness-perms--auto-allow-tools` |
| `harness-perms-auto-timeout` | `harness-perms--auto-timeout` |
| `harness-bedrock-models-ttl` | `harness-bedrock--models-ttl` |
| `harness-bedrock-request-timeout` | `harness-bedrock--request-timeout` |
| `harness-bedrock-max-tokens` | `harness-bedrock--default-max-tokens` |
| `harness-bedrock-prompt-caching` | `harness-bedrock--prompt-caching` |
| `harness-bedrock-thinking-budgets` | `harness-bedrock--thinking-budgets` |
| `harness-bedrock-max-retries` | `harness-bedrock--max-retries` |
| `harness-bedrock-model-defaults` | `harness-bedrock--model-defaults` |
| `harness-bedrock-aws-program` | `harness-bedrock--aws-program` |
| `harness-bedrock-credential-timeout` | `harness-bedrock--credential-timeout` |
| `harness-provider-claude-interrupt-timeout` | `harness-provider-claude--interrupt-timeout` |
| `harness-provider-claude-quota-ttl` | `harness-provider-claude--quota-ttl` |
| `harness-provider-claude-probe-timeout` | `harness-provider-claude--probe-timeout` |
| `harness-provider-claude-progress-interval` | `harness-provider-claude--progress-interval` |
| `harness-provider-copilot-interrupt-timeout` | `harness-provider-copilot--interrupt-timeout` |
| `harness-provider-copilot-startup-timeout` | `harness-provider-copilot--startup-timeout` |
| `harness-provider-copilot-quota-ttl` | `harness-provider-copilot--quota-ttl` |
| `harness-provider-demo-delay` | `harness-provider-demo--delay` |
| `harness-openai-models-ttl` | `harness-openai--models-ttl` |
| `harness-openai-request-timeout` | `harness-openai--request-timeout` |
| `harness-openai-progress-interval` | `harness-openai--progress-interval` |
| `harness-sandbox-bwrap-program` | `harness-sandbox--bwrap-program` |
| `harness-sandbox-systemd-run-program` | `harness-sandbox--systemd-run-program` |
| `harness-sandbox-home` | `harness-sandbox--home` |
| `harness-session-save-delay` | `harness-session--save-delay` |
| `harness-skills-prompt-limit` | `harness-skills--prompt-limit` |
| `harness-skills-description-limit` | `harness-skills--description-limit` |
| `harness-tasks-naming-prompt` | `harness-tasks--naming-instructions` |
| `harness-tasks-refine-prompt` | `harness-tasks--refine-prompt` |
| `harness-tasks-refine-tool-calls` | `harness-tasks--refine-tool-calls` |
| `harness-tasks-start-text` | `harness-tasks--start-message` |
| `harness-tasks-reject-text` | `harness-tasks--reject-message` |
| `harness-tasks-btw-prompt` | `harness-tasks--btw-prompt` |
| `harness-tasks-merge-attempts` | `harness-tasks--merge-attempts` |
| `harness-tasks-merge-session-name` | `harness-tasks--merge-session-name` |
| `harness-tasks-resume-prompt` | `harness-tasks--resume-prompt` |
| `harness-tools-timeout` | `harness-tools--timeout` |
| `harness-tools-fs-glob-limit` | `harness-tools-fs--glob-limit` |
| `harness-tools-fs-list-limit` | `harness-tools-fs--list-limit` |
| `harness-tools-fs-grep-timeout` | `harness-tools-fs--grep-timeout` |
| `harness-tools-fs-binary-probe-bytes` | `harness-tools-fs--binary-probe-bytes` |
| `harness-tools-fs-line-count-limit` | `harness-tools-fs--line-count-limit` |
| `harness-tools-notify-rate-limit` | `harness-tools-notify--rate-limit` |
| `harness-tools-sessions-wait-default` | `harness-tools-sessions--wait-default` |
| `harness-tools-sessions-wait-max` | `harness-tools-sessions--wait-max` |
| `harness-tools-sessions-grep-program` | `harness-tools-sessions--grep-program` |
| `harness-bash-program` | `harness-tools-shell--program` |
| `harness-bash-default-timeout` | `harness-tools-shell--default-timeout` |
| `harness-bash-max-timeout` | `harness-tools-shell--max-timeout` |
| `harness-web-fetch-max-chars` | `harness-tools-web--fetch-max-chars` |
| `harness-web-fetch-timeout` | `harness-tools-web--fetch-timeout` |
| `harness-web-user-agent` | `harness-tools-web--user-agent` |
| `harness-web-search-max-count` | `harness-tools-web--search-max-count` |
| `harness-worktree-subdirectory` | `harness-worktree--subdirectory` |
| `harness-ui-btw-window-parameters` | `harness-ui-btw--window-parameters` |
| `harness-chat-history-limit` | `harness-chat--history-limit` |
| `harness-chat-history-page` | `harness-chat--history-page` |
| `harness-chat-compose-max-lines` | `harness-chat--compose-max-lines` |
| `harness-chat-tool-output-limit` | `harness-chat--tool-output-limit` |
| `harness-chat-render-interval` | `harness-chat--render-interval` |
| `harness-chat-coalesce-threshold` | `harness-chat--coalesce-threshold` |
| `harness-chat-image-max-height` | `harness-chat--image-max-height` |
| `harness-ui-config-default-scope` | `harness-ui-config--default-scope` |
| `harness-ui-markdown-fontify-limit` | `harness-ui-markdown--fontify-limit` |
| `harness-ui-media-thumbnail-width` | `harness-ui-media--thumbnail-width` |
| `harness-ui-sessions-buffer-name` | `harness-ui-sessions--buffer-name` |
| `harness-ui-tasks-tick` | `harness-ui-tasks--tick-interval` |
| `harness-ui-tasks-notify-review` | `harness-ui-tasks--notify-review` |
| `harness-ui-tree-lane-width` | `harness-ui-tree--lane-width` |
| `harness-ui-tree-lane-colors` | `harness-ui-tree--lane-colors` |
| `harness-ui-tree-expand-limit` | `harness-ui-tree--expand-limit` |
| `harness-ui-usage-buffer-name` | `harness-ui-usage--buffer-name` |
| `harness-ui-usage-chart-height` | `harness-ui-usage--chart-height` |
| `harness-ui-worktree-buffer-name` | `harness-ui-worktree--buffer-name` |
| `harness-notifications-desktop-icon` | `harness-notifications-desktop--icon-name` |
| `harness-notifications-desktop-notify-send-program` | `harness-notifications-desktop--notify-send` |

Two of these deserve their own note, because they look like user
choices and are not:

- **Prompts** (`harness-agent--base-system-prompt`,
  `harness-tasks--refine-prompt`, ...) are part of the harness's
  behaviour contract, not settings: modules already compose them
  through the `agent/system-prompt` and `naming/system-prompt` filters,
  which is the extension point that survives prompt rewrites.  A user
  who wants to add instructions should add a filter or a skill.
- **Model metadata** (`harness-bedrock--model-defaults`,
  `harness-bedrock--thinking-budgets`) is a table the provider keeps
  about models it cannot ask.  Per-endpoint `:models` entries and the
  provider's capability keys are the supported way to correct it.

## Migration

Someone who had set one of the options above in an init file or a
`.dir-locals.el` can keep the behaviour by setting the constant, which
still works:

```elisp
(with-eval-after-load 'harness-compaction
  (setq harness-compaction--context-reserve 40000))
```

For the harness process, the same line in `harness-server-init-file`
applies.  A stale `.dir-locals.el` entry for a removed option is inert:
Emacs sets the (now internal) variable, and nothing reads it.

The merges that change the effective value are:

| If you set | Use instead |
|---|---|
| `harness-default-model` | `harness-model` (the old name still works as an alias) |
| `harness-merge-git-program`, `harness-tasks-git-program`, `harness-worktree-git-program` | nothing: put git on `exec-path` |
| `harness-debug-backtraces t` | `(setopt harness-log-level 'debug)` |
| `harness-ui-worktree-branch-prefix` | `harness-worktree-branch-prefix` |
| `harness-context-reserve` | the internal `harness-compaction--context-reserve`, if you really must |
| `harness-bedrock-max-tokens`, `harness-bedrock-prompt-caching` | the endpoint's `:max-tokens` and `:prompt-caching` keys in `harness-bedrock-endpoints` |
| `harness-perms-auto-allow-tools` | `harness-perms-rules`, with `(:tool NAME :behavior allow)` |

## The settings page now

`C-c h S` (`M-x harness-settings`) leads with the options that go
together by user story, in the order the story is told:

| Section | Options |
|---|---|
| New sessions | `harness-model`, `harness-thinking`, `harness-permission-mode`, `harness-non-interactive`, `harness-budget` |
| Files and safety | `harness-allowed-directories`, `harness-sandbox-policy`, `harness-perms-rules`, `harness-perms-auto-model` |
| Task board | `harness-tasks-model`, `harness-tasks-thinking`, `harness-tasks-permission-mode`, `harness-tasks-non-interactive`, `harness-tasks-context-limit`, `harness-tasks-require-verification`, `harness-tasks-max-running`, `harness-tasks-worktrees` |
| Notifications | `harness-tasks-notify-events`, `harness-notifications-providers`, `harness-gotify-url`, `harness-gotify-token` |
| Models and services | `harness-openai-endpoints`, `harness-bedrock-endpoints`, `harness-websearch-provider`, `harness-websearch-builtin`, `harness-brave-api-key` |

Everything else on the page is folded into one *Advanced* line saying
how many settings it holds and how many were changed; `a`, or the
button, shows them by module, and the interface's own options are one
more click away, in Customize.

For code that lists settings (`config/describe`), each setting now
carries `:section`, and the answer carries the ordered `:sections`
list; a client that knows nothing about sections still gets every
setting.  A harness whose modules are all disabled, and therefore names
no sections, lists its layered settings in one *Session defaults*
section.

## Advanced options kept (24)

These stayed options because they are real choices, just not common
ones: `harness-log-level`, `harness-naming-auto`,
`harness-notifications-desktop-backend`,
`harness-provider-claude-program`, `harness-provider-claude-extra-args`,
`harness-provider-claude-permission-args`,
`harness-provider-copilot-program`,
`harness-provider-copilot-default-model`,
`harness-provider-copilot-extra-args`, `harness-sandbox-backend`,
`harness-sandbox-extra-read-only-dirs`, `harness-skills-directories`,
`harness-tasks-refine-model`, `harness-tasks-refine-thinking`,
`harness-tasks-branch-prefix`, `harness-tasks-resume-interrupted`,
`harness-tasks-store-in-repository`,
`harness-tasks-notify-providers`, `harness-tools-max-output-chars`,
`harness-usage-warn-fraction`, `harness-anthropic-admin-api-key`,
`harness-worktree-directory-function`, `harness-worktree-branch-prefix`.

(`harness-perms-rules` and the sectioned options are in the sections
above; the 12 startup options listed in *Result* are the other global
ones.)

## Feature duplication (the same audit on tools)

The same question applies to features: where two tools or commands are
one user need with a parameter.  These are the findings; the ones
marked *done* were fixed, the rest are recommendations, not changes.

| Overlap | Verdict |
|---|---|
| `write_file` and `edit_file` | One need ("change a file") with two parameters (whole file, or a patch). Kept separate: the agent chooses per call, and both are documented side by side |
| `glob`, `grep`, `list_dir`, `file_info`, `read_file` | The fs tools are verbs on files, not duplicates. Their limits are now constants, so they compose |
| `emacs_*` tools and the `elisp` tool | Not one need: `elisp` evaluates in a background Emacs, and reaches the user's only when a call asks for it and the user allowed it (`harness-elisp-allow-ui-eval`); the narrow, read-only tools are how the agent reads the user's Emacs unaided. Keep both, with `elisp` under the stricter permission |
| `web_search` and the provider's own search | Already one feature with a parameter (`harness-websearch-builtin`), exactly the pattern this audit asks for |
| `session_wait` and `task_wait` | One waiting mechanism with different predicates; both already accept the same timeout options, with one default (now an internal constant) |
| `fork` and `btw` | Fork copies context, BTW deliberately does not. One "start a side conversation" UI with a parameter would hide the price difference; keep both, they are named for what they do |
| Task worktrees vs `harness-worktrees` (UI) | One mechanism (the worktree module) with two entry points: automatic per task, and manual from the list. Entry points are fine; the duplicate branch prefix was not (removed) |
| Task notifications vs the `notify` tool | Both send through the notification providers; the task one is a policy (when), the tool is an action (now). Keep, but the tool's rate limit is a constant so it cannot be configured into uselessness |
| `plan` and `todo_write` | Different lifetimes (a plan for a task, a checklist for a turn). Keep |
| `usage` dashboard and budgets | One page: a budget is a line on the dashboard, not a second feature. Already so |
| Task mode and sessions | One is a view of the other, sharing the session composer; the design doc already requires reuse rather than a second implementation |
| `harness-tasks-refine-model`/`-thinking` | A second model knob for the write-up step. It is a real choice (cheap model for a summary), but the next such knob should be a parameter of the refine session, not a new global |

The general recommendation: before adding a tool or a command, check
whether an existing one can take a parameter; before adding a setting,
check the tier table above.  When a feature is genuinely rare, prefer
an elisp function or a filter over a new interactive command, so the
menu and the settings page keep telling one story.

## Adding an option from now on

1. Is it a decision the user makes, or a detail of how the harness
   works?  A detail becomes a `defconst`/`defvar` named
   `MODULE--thing` with a docstring saying why the value is what it is.
2. Does an option already mean this?  If not, does the module of the
   option own the decision?  Put it there, not in the module that
   happens to read it.
3. Does it belong to a user story?  Add it to that section of
   `harness-config-sections` (which is what the settings page and
   `config/describe` use); otherwise leave it advanced, in the
   `harness` group, and it will be found under *Advanced*.
4. Should a project be able to override it?  Add it to
   `harness-config-keys` with a `:safe` predicate, and to a section.
5. Is it a secret?  Name it `...-api-key`, `-token`, `-secret` or
   `-password`: the machinery already keeps such values out of
   `.dir-locals.el`, the settings page and the wire.
6. Run `test/harness-config-test.el`: it fails when a layered setting
   is missing from the sections, or a section names an option that no
   longer exists.

## Verification

- `scripts/lint.sh` compiles every file.
- `scripts/test.sh` runs the suites; the settings suites cover the
  sections, the folded advanced line, saving, scopes and secrets.
- `test/harness-config-test.el` gains
  `harness-config-describe-puts-common-settings-in-sections` and
  `harness-config-sections-name-real-options`.
- The page was rendered outside the tests too: a batch Emacs with the
  state layer, the UI and the settings page draws it and prints the
  buffer, which is how the sections, the *Advanced* line and the
  *Interface* button were read as a user would see them (project scope,
  global scope, and advanced settings shown and folded).
- `scripts/test.sh test/harness-ui-config-test.el` covers the layout
  itself: the section headings, the count and "changed" note on the
  *Advanced* line, the fold and unfold, the scope switch from the fold
  and the menu entries.
