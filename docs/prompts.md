# The prompt library

Every prompt the harness's own model calls send is a named entry in
one registry: `harness-prompts--registry` in
[lisp/harness-prompts.el](../lisp/harness-prompts.el).  The calls are
the one-off ones that go through `harness-small-ask` (a session's name,
the permission judge and the summary of a prompt, the session judge, a
recap, a compaction's summary, the Insights summary, the todo sync, the
task board's search, the cache warmer, the companion pet and memory
consolidation) and the provider checks, which are their own requests.  The system prompt a
conversation is assembled with is not one of them; it is the
conversation's own prompt, built by `harness-agent--system-prompt`.

Each entry has

- a **name**, a symbol the call site passes to `harness-prompt`;
- a **purpose**, what the prompt is for and which call sends it;
- its **variables**, the `{{name}}` placeholders a template may use;
- and its **template**, the default text.

## Reading and auditing

**`M-x harness-prompts`** is the prompt page.  It lists every prompt
grouped by module, folded to its name, its purpose and the models an
override covers.  `TAB` or `RET` unfolds a prompt to its call site, its
variables and its template; the same key folds it again.  With a prefix
argument (`C-u M-x harness-prompts`) the page asks for a model and shows
the template that model is sent, overrides and all, with a button to go
back to the registry's own text.

The top of the page lists the overrides, each with **Edit** and
**Remove** buttons, and three more:

- **Customize** opens the `harness-prompts` customization group
  ([below](#in-customize));
- **Add…** asks for a prompt and a model, and opens the editor;
- **Audit** runs `harness-prompts-audit` and reports what it finds: a
  duplicate name, an undeclared placeholder, an unused variable, a
  prompt without a purpose, an override naming an unknown prompt or an
  undeclared variable.  It returns nil when the library is sound.

`harness-prompt-describe NAME` returns an entry as a string, for a
program or a message.  `scripts/test.sh test/harness-prompts-test.el`
checks the registry, every call site, the page and the examples below.

The prompts are in the order they were added, grouped by module, in
[the table below](#the-prompts).

## Overriding a prompt

An override replaces a prompt's text for one model.  The default, with
no override set, sends every prompt exactly as it is written in the
registry, so adding this library changed no model call's text.  There
are two ways to edit one: the page and Customize.  Both save through
Customize, so the entry is kept in your custom file and survives a
restart.

### From the page

`M-x harness-prompts`, `TAB` on a prompt to unfold it, then `e` to edit
its override.  Choose the model (or *every model not named*), edit the
template in the buffer that opens, and type `C-c C-c` to save.  `C-c
C-k` cancels, `C-c C-d` removes the override, and `C-c C-r` puts the
registry's default back in the buffer.  `a` adds an override, and `x`
removes one.  The unfolded prompt's **Edit…** and **Remove…** buttons do
the same; **Model…** shows what one model is sent, and **Defaults** goes
back to the registry's text.

The editor starts from the template the chosen model is sent now: its
own override, else the `t` fallback, else the registry's default.  So
changing a model's wording does not begin from a blank buffer.  Saving
stores `harness-prompt-overrides` through `harness-save-user-option`,
the same way the harness's other settings are stored, and the page
updates at once.

### In Customize

`M-x customize-group RET harness-prompts RET`, or the page's
**Customize** button, edits the overrides as a structured option.  `INS` adds a model; `INS` inside it adds a prompt, whose name
is a menu of the registry's names; its template is a string field.
`DEL` removes an entry, `Apply` sets it and `Save` stores it in your
custom file, as Customize does for any option.  The same group holds
`harness-prompt-overrides-file`.

### In your init file

`harness-prompt-overrides` is an alist of model id to prompt overrides:

```elisp
(setq harness-prompt-overrides
      '(("deepseek:deepseek-chat"
         . ((recap-system . "You write the card's one-line progress recap.  Be concrete and dry.")
            (event-classifier-system . "Classify one harness event; answer in one line of JSON.")))
        (t . ((naming-system . "Name this conversation in a few words.")))))
```

A key is a model id exactly as the harness names it, `PROVIDER:NAME`,
or `t` for every model no exact entry covers.  The value is an alist of
prompt name to template.  A template is a string; it may use the
prompt's variables, written `{{name}}`.

### In a file

`harness-prompt-overrides-file` reads the same alist from a file, so it
can be edited while the harness runs:

```elisp
;; ~/.emacs.d/harness/prompt-overrides.el
(("deepseek:deepseek-chat"
  . ((recap-system . "You write the card's one-line progress recap."))))
```

Set it to the file's path:

```elisp
(setq harness-prompt-overrides-file "~/.emacs.d/harness/prompt-overrides.el")
```

A relative path is relative to `harness-state-directory`.  The file is
read again when its modification time changes.  Read-time evaluation is
off, so a file cannot run code while it is read.

### Which entry wins

The most specific entry wins:

1. an exact model entry over `t`;
2. `harness-prompt-overrides` over the file at the same specificity;
3. otherwise the registry's default template.

A model's provider may change its simple tier, so an override on
`PROVIDER:NAME` follows the model the call actually asks, not the
session's model.  `harness-prompt-describe` with a model shows the
template that model would be sent.

### Variables

An override template may use any variable the prompt's entry declares,
and can leave out any it does not need.  Using a placeholder the entry
does not declare is an error, as is a missing variable at render time;
`harness-prompts-audit` reports an entry whose default template and
variables disagree, and an override that uses an undeclared
`{{placeholder}}`, so a typo shows in **Audit** rather than in a model
call.

For example, `event-classifier-question` declares `{{tag}}`,
`{{instructions}}`, `{{event}}`, `{{actions}}` and `{{action-json}}`;
`perms-summary-question` declares the call's fields and `{{paths}}`,
which is either a "Paths it is about" line or empty.

## One-off calls and the API

Every one-off call the harness makes goes through `harness-prompt-ask':

```elisp
(harness-prompt-ask 'recap-system        ; a name, or a list of names
                    (list :model model :system system :messages messages)
                    (list :label "recap" :on-event on-event))
```

It checks that every name is registered (`harness-prompt-error`
otherwise), puts them on the request as `:prompts`, and hands it to
`harness-small-ask`.  That function is the one place a one-off call is
made, and it refuses a request without `:prompts`:

```elisp
(harness-small-ask (list :model model :system "raw text" :messages messages))
;; => harness-prompt-error: A one-off call must name its prompts; use `harness-prompt-ask'
```

`:prompts` is taken out before the provider sees the request, so a call
cannot reach a model without the registry's say.  The test
`harness-prompts-only-the-wrapper-calls-small-ask` fails if the
harness's own source calls `harness-small-ask` directly.

### A module's own prompt

A module that needs a prompt of its own registers it, instead of passing
text to a call:

```elisp
(require 'harness-prompts)

(harness-prompt-register 'my-module-greeting
                         :module 'my-module
                         :purpose "Greets a provider check."
                         :used-by "my-module--request"
                         :variables '((:name "name" :description "Who to greet."))
                         :template "Hello {{name}}.")

(harness-prompt-ask 'my-module-greeting
                    (list :model model
                          :system (harness-prompt 'my-module-greeting '(:name "Ada"))
                          :messages messages))
```

A registered prompt joins `harness-prompt-names`, the page, the audit,
the overrides and the Customize menu at once; the audit reports it like
the built-in ones (an undeclared `{{placeholder}}`, a missing purpose).
Its module is the one it registers with, so it is grouped with that
module on the page.

### Why a library, not a module

The registry is a library, not a module, because both sides of the
process split read it: the harness's judges and one-off calls on the
server side, and the prompt page in the UI process, which does not load
server modules.  It starts nothing and holds no state beyond the
file-override cache, so loading it costs one file.  Optionality is at
the call, not at the load: a module that never makes a one-off call
names no prompt and requires nothing of this library, and a module that
does is already loading `harness-small`, where the check lives -- a
module cannot use the one-off API without the registry, and a module
that does not use it gains no hooks, options or timers from it.

## The prompts

### naming

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `naming-system` | Titles a new conversation in three to six words. | none | harness-naming--system-prompt |
| `naming-request` | Asks for a title of the whole conversation, after its transcript. | none | harness-naming--messages |
| `naming-opening` | Introduces the opening message a title is written from. | none | harness-naming--opening-blocks |
| `naming-latest` | Introduces the latest message when the conversation has moved on. | none | harness-naming--opening-blocks |
| `naming-opening-request` | Asks for a title from a conversation's opening and latest message. | none | harness-naming--opening-blocks |

### tasks

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `task-naming-instructions` | Adds the task board's ticket-title instruction to a task's naming prompt. | none | harness-tasks--naming-prompt |

### recap

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `recap-system` | Tells the model how to write a task card's one-sentence recap. | none | harness-recap--request |
| `recap-ask` | The last line of a recap request. | none | harness-recap--prompt |

### compaction

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `compaction-system` | Tells the model how to write the handoff summary a compaction keeps. | none | harness-compaction--request |
| `compaction-request` | Asks for the conversation's summary at the end of a compaction request. | none | harness-compaction--with-ask |

### insights

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `insights-system` | Tells the model how to read the figures and write the Insights report. | none | harness-insights--request |

### todo-sync

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `todo-sync-system` | Tells the model how to write a session's todo list. | none | harness-todo-sync--dumb-request, harness-todo-sync--own-request |
| `todo-sync-ask` | The last line of a request that has the harness's dumb agent write the list. | none | harness-todo-sync--prompt |
| `todo-sync-fork-ask` | The instructions put to a session's own agent when it writes its list. | none | harness-todo-sync--fork-question |

### tasks-search

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `search-system` | The task board search's system prompt: what to show, run and answer. | none | harness-tasks-search--request |
| `search-final` | Closes what a search's model asked to see and asks for its answer. | none | harness-tasks-search--closing-text |

### pet

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `pet-hatch-system` | Asks for a newly hatched companion's name and personality. | none | harness-pet--hatch-request |
| `pet-say-system` | Gives a companion its voice: who it is and how it says one line. | `{{name}}` The pet's name.<br>`{{rarity}}` Its rarity, as a symbol name: common, rare, legendary.<br>`{{species}}` Its species, as a symbol name.<br>`{{personality}}` Its personality, prefixed with "Your personality: ", or empty.<br>`{{stats}}` Its stats as "DEBUGGING 62, PATIENCE 30, ...".<br>`{{actions}}` What it may do between asterisks, or that it may do none. | harness-pet--say-system |

### perms

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `perms-judge-system` | The auto-mode permission judge's safety instructions. | none | harness-perms--judge-system-prompt |
| `perms-judge-question` | Describes one tool call to the permission judge and asks for its verdict. | `{{tool}}` The tool's name.<br>`{{kind}}` The tool's kind, as `exec', `write' and so on.<br>`{{description}}` What the tool does: the first sentence of its description.<br>`{{input}}` The call's input as a JSON block, cut to the judge's limit.<br>`{{cwd}}` The session's working directory.<br>`{{roots}}` The allowed roots, one "- PATH" per line.<br>`{{harness}}` Where the harness lives, or empty. | harness-perms--judge-text |
| `perms-summary-system` | Tells the model how to explain a blocked tool call to the user. | none | harness-perms--summary-request |
| `perms-summary-question` | Describes one blocked call to the model that summarizes it for the user. | `{{tool}}` The tool's name.<br>`{{kind}}` The tool's kind.<br>`{{description}}` What the tool does: the first sentence of its description.<br>`{{cwd}}` The session's working directory.<br>`{{paths}}` A "Paths it is about: ..." line and its newline, or empty.<br>`{{reason}}` Why the user is asked about the call.<br>`{{input}}` The call's input as a JSON block, cut to the summary's limit. | harness-perms--summary-text |

### supervisor

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `session-judge-system` | Tells the session judge how to choose supervise or hands-on. | none | harness-supervisor--judge-ask |
| `session-judge-question` | Puts a session's opening message to the session judge. | `{{message}}` The opening message, cut to the judge's limit. | harness-supervisor--judge-question |

### tools-events

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `event-classifier-system` | Tells an event watch's classifier how to read an event and choose an action. | none | harness-tools-events--classify |
| `event-classifier-question` | Puts the watching agent's instructions and one event to the classifier. | `{{tag}}` A short id fencing the instructions and the event.<br>`{{instructions}}` The watch's instructions, trimmed.<br>`{{event}}` The event as one line of JSON.<br>`{{actions}}` The actions the classifier may answer, comma separated.<br>`{{action-json}}` The actions as a JSON alternation, quoted and joined with \|. | harness-tools-events--classifier-text |

### cache-warm

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `cache-warm-ping` | The harmless message that reads a session's prompt cache again. | none | harness-cache-warm--request |

### provider-check

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `provider-check-system` | The plain system prompt a provider check's completion is sent. | none | harness-provider-check--request |
| `provider-check-greeting` | Asks for the short greeting a completion check expects. | none | harness-provider-check--check-completion |
| `provider-check-image` | Asks about the image a vision transport check sends. | none | harness-provider-check--check-image-input |
| `provider-check-tool` | Asks the model to call check_echo with ping, for the tool transport check. | none | harness-provider-check--tool-turn |
| `provider-check-vision` | Asks for the colour of the red image in the vision check. | none | harness-provider-check--check-vision |
| `provider-check-instructions` | Asks the model to resubmit, to check it follows a tool description's label. | none | harness-provider-check--check-instructions |
| `provider-check-instructions-system` | The system prompt of the check that the model follows a tool's instructions. | none | harness-provider-check--check-instructions |
| `provider-check-cache-probe` | One synthetic cache probe message, isolated by its nonce. | `{{nonce}}` The synthetic prefix's fresh identifier. | harness-provider-check--cache-specs |
| `provider-check-cache-resume` | The short resumed request after a synthetic keep-warm message. | `{{nonce}}` The synthetic prefix's fresh identifier. | harness-provider-check--cache-specs |

### secret-sandbox

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `secret-sandbox-withheld` | Tells the agent that a locked run's output, exit status and duration are not returned. | none | harness-secret-sandbox--withheld |

### memory

| Prompt | Purpose | Variables | Used by |
|---|---|---|---|
| `memory-consolidate-system` | Tells a judge how to merge and tidy the memories of one scope. | none | harness-memory--consolidate |
| `memory-consolidate-request` | Lists the memories a consolidation judge is to merge. | `{{memories}}` The memories of the scope, one line each: [id] kind: text. | harness-memory--consolidate |
