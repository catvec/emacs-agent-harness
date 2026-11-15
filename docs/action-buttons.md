# Action buttons say what they do

## What went wrong

Commit `7767338` ("Make the UI copy nouns, noun phrases and adjectives")
fixed a real problem -- the interface was full of sentences -- but applied
the noun rule to controls that act.  A copy pass rewrote the review
banner's buttons:

| before | after the pass | what the button does |
| --- | --- | --- |
| `[Verify]` | `[Verification]` | accepts the work and merges its branch |
| `[Send back]` | `[Return]` | sends the work back with feedback |
| `[Keep working]` | `[Working phase]` | takes the task out of review |

and the same substitution ran through the board, the computers page, the
server page and the Flutter client: `[Register]` became `[Registration]`,
`[Revoke]` became `[Revocation]`, `[Reconnect]` became `[Reconnection]`,
`[Unarchive]` became `[Restoration]`, `[Mark done]` became `[Completion]`,
`[Steer]` became `[Steering]`.

A noun names a thing.  A button names what pressing it does, so a button
labelled with a category noun leaves the person guessing whether
`[Verification]` opens a verification report or performs the
verification.  The noun rule was right about headings, states, labels and
navigation; it was wrong about actions, and nothing in the repository
said so.

## The rule, split in two

The interface text is still nouns, noun phrases and adjectives -- with one
exception, now stated in the rules:

- **A control that acts takes the imperative**: `[Verify]`, `[Register]`,
  `[Revoke]`, `[Reconnect]`, `[Send back]`, `[Keep working]`, `[Start]`,
  `[Stop]`, `[Mark done]`.
- **A noun stays a noun** for what a control names rather than does:
  navigation and the page it opens (`[Computers]`, `[Review Changes]`,
  `[Settings]`), a heading, a category, a field's label, an object, a
  state (`connected`, `Ready for review`).
- **Menus follow the same split**: an entry that acts is the verb
  (`Verify (accept)`, `Send back with feedback`), an entry that opens a
  page or names a setting stays a noun phrase (`Session switch`).
- **An echo-area report of an outcome stays a noun phrase**
  because it names what happened, not an act to do: `Verification
  failure: ...`, which says which operation failed and reads correctly,
  where `Verify failure` would not.  A report that names the act the
  command performed keeps the command's own word, `Revoke · /path/`,
  because it is the button's name in the past tense of a report.

## The copy inventory

Every changed string, by surface.  The "why" column is the
classification the rule asks for.

### Emacs: the review banner (`harness-ui-review.el`)

| before | after | why |
| --- | --- | --- |
| `[Verification]` | `[Verify]` | acts on the task |
| `[Return]` | `[Send back]` | acts on the task |
| `[Working phase]` | `[Keep working]` | acts on the task |
| tooltip `acceptance of the work...` | `accept the work; its branch merges` | says the act |
| tooltip `feedback in the box, then C-c C-c` | `send it back with the feedback in the box, then C-c C-c` | says the act |
| tooltip `task out of review, the work continuing` | `keep the task at work, out of review` | says the act |
| menu `Verification` / `Return with feedback` / `Working phase` | `Verify (accept)` / `Send back with feedback` / `Keep working (leave review)` | menus act |

`[Review Changes]` stays a noun phrase: it opens the changes.

### Emacs: the task board (`harness-ui-tasks.el`)

| before | after | why |
| --- | --- | --- |
| `Verification` | `Verify` | acts |
| `Return` | `Send back` | acts |
| `Working phase` | `Keep working` | acts |
| `Restoration` | `Unarchive` | acts |
| `Completion` | `Mark done` | acts |
| `Refinement` | `Refine` | acts |
| `Write-up` | `Write it up` | acts |
| `Approval` / `Denial` | `Allow` / `Deny` | acts |
| `Steering` | `Steer` | acts |
| `Deletion...` | `Delete...` | acts |
| `Merge retry` | `Retry merge` | acts |
| `Manual review` | `Put in review` | acts |

`Open`, `Start`, `Pause`, `Resume`, `Stop`, `Drop`, `Archive`, `Queue`
were already imperatives and are unchanged.

### Emacs: the computers page (`harness-ui-computers.el`)

| before | after | why |
| --- | --- | --- |
| `[Registration]` | `[Register]` | acts |
| `[Unregistration]` | `[Unregister]` | acts |
| `[Revocation]` | `[Revoke]` | acts |
| `[Preference]` | `[Prefer]` | acts |
| `[Resource refresh]` | `[Refresh resources]` | acts |
| `[Computer list]` | `[Refresh list]` | acts |
| tooltip `registration of this computer...` | `register this computer with the harness` | says the act |
| tooltip `unregistration of the computer at point` | `unregister the computer at point` | says the act |
| tooltip `revocation of the computer at point...` | `revoke the computer at point...` | says the act |
| tooltip `preferred computer of this session` | `make it the preferred computer of this session` | says the act |

`[View]`, `[Control]`, `[Return]` and `[Grant]` keep their labels: `View`,
`Control` and `Grant` are verbs already, and `Return` gives control back
-- it is the counterpart of `Control` and reads as a verb there.  Their
tooltips said the act as a noun (`screen view of ...`, `control of ...`,
`control return of ...`) while the rest of the page's said it as an
imperative, so they now do too.

### Emacs: the workspace computer bar (`harness-ui-workspace.el`)

The bar was missed by the first pass: it is not a `harness-ui-button`
page like the others, and two of its labels were nouns for acts.

| before | after | why |
| --- | --- | --- |
| `Startup` | `Start` | acts |
| `Takeover` | `Take over` | acts |
| `Control return` | `Return control` | acts |
| `VNC page` | `Open VNC page` | acts |
| tooltip `workspace computer startup` | `start the workspace computer (s)` | says the act |
| tooltip `workspace computer stop` | `stop the workspace computer (S)` | says the act |
| tooltip `workspace computer restart` | `restart the workspace computer (R)` | says the act |
| tooltip `reviewer control` | `take control from the agent (t)` | says the act |
| tooltip `agent control` | `return control to the agent (T)` | says the act |
| tooltip `noVNC page` | `open the noVNC page in a browser (o)` | says the act |
| tooltip `current screen picture` | `take a picture of the screen (p)` | says the act |
| tooltip `computer refresh` | `refresh the computer's state (r)` | says the act |

`Stop`, `Restart`, `Screenshot` and `Refresh` were already imperatives.
The hint line under the bar follows the labels: `s · start`,
`t · take over`, `T · return control`, `o · open VNC page`.
`Back` and `Workspace` stay nouns (they open a page), and their tooltips
now say the act: `go back to the node or page before this one`,
`open the workspace chat`.

### Emacs: the voice transcript and the chat's tool calls

| surface | before | after | why |
| --- | --- | --- | --- |
| voice pipeline strip | `[Pipeline details]` | `[Show details]` | acts, and pairs with `[Hide details]` |
| voice pipeline tooltip | `Pipeline details` | `show the pipeline details` | says the act |
| chat tool-call toggle | tooltip `tool call display` | `show or hide the tool calls` | says the act |

The `Pipeline details` *heading* under the strip keeps its name: it labels
the panel the button opens.

### Emacs: the server page (`harness-ui-server.el`)

| before | after | why |
| --- | --- | --- |
| `[Reconnection]` | `[Reconnect]` | acts |
| `[Module reload]` | `[Reload modules]` | acts |
| `[Address copy]` | `[Copy address]` | acts |
| `[Measurement]` | `[Measure]` | acts |
| `[Local harness]` | `[Use local harness]` | acts |
| echo `Address copy: ...` | `Copy address: ...` | the act, in the past tense of a report |

`[Connection...]`, `[Session list]` and `[Module list]` stay nouns: they
open a form or a list.

### Emacs: the access page, the task search and the report

| surface | before | after | why |
| --- | --- | --- | --- |
| access row | `[Revocation]` | `[Revoke]` | acts |
| access tooltip | `grant revocation · /path/` | `revoke the grant · /path/` | says the act |
| access echo | `Revocation · /path/` | `Revoke · /path/` | names the act done |
| access confirm | `Revocation · every session · /path/` | `Revoke for every session · /path/` | says the act |
| task search button | `Verification` / `Completion` / `Return` | `Verify` / `Mark done` / `Send back` | acts |
| task search heading | `Verification of ...` | unchanged | names the proposal |

### Flutter: the task bar's completion dialog

The task bar's confirm button was the one action label the first pass
left nominalized in the app.

| before | after | why |
| --- | --- | --- |
| confirm `Completion` | `Mark done` | acts, and matches the menu entry that opens it |

The dialog's title, `Task completion`, stays a noun phrase: it names the
operation, as `Task stop`, `Task drop` and `Task deletion` do.

### Flutter: the Computers page and the task bar

| before | after | why |
| --- | --- | --- |
| `Registration` | `Register` | acts |
| `Reconnection` | `Reconnect` | acts |
| `Disconnection` | `Disconnect` | acts |
| `Revocation` (both the client card's and a computer's grant) | `Revoke` | acts |
| `Preference` | `Prefer` | acts |
| `File import` | `Import file` | acts |
| `Capture off` | unchanged | names a state |

| before | after | why |
| --- | --- | --- |
| `confirmLabel: 'Return'`, title `Return` | `Send back` | confirms an act |
| `confirmLabel: 'Deletion'` (task, session, browser data, site data) | `Delete` | confirms an act |
| `confirmLabel: 'Disconnection'` | `Disconnect` | confirms an act |
| `_action('Revocation...')`, `_action('Revocation')` | `Revoke...`, `Revoke` | acts |
| `_action('Deletion...')`, `_action('Deletion')` | `Delete...`, `Delete` | acts |
| `_action('Removal')` | `Remove` | acts |

The Flutter task actions (`task_actions.dart`) were already imperatives
(`Start now`, `Send back`, `Verify and merge`, `Mark complete`) and are
unchanged.

## Keeping the regression from coming back

- **`CLAUDE.md`** gains the split as its own rule, naming the exact words
  that were the regression, so an agent reading the instructions cannot
  read the noun rule as covering buttons.
- **`docs/ui-guide.md`** carries the same rule in "Rules of the house",
  the menu rule is rewritten to the split, and the copy-first checklist's
  first item now says that a control that acts takes its imperative.
- **The `tools-dev` system prompt** (`.harness/plugins/dev/harness-tools-dev.el`)
  carries it to every agent in this repository, with the regression named,
  and `harness-tools-dev-test.el` asserts the words are in the prompt.
- **Exact rendered-copy assertions**:
  `harness-ui-review-banner-words-its-actions-as-verbs` is new and holds
  the banner's three labels, the absence of the three nouns, the noun
  phrase that stays one, and the three tooltips;
  `harness-ui-tasks-test` holds the board's action list
  (`("Verify" "Send back")`), its cards' rendered buttons and its menu;
  `harness-ui-computers-test` holds the page's buttons, their tooltips and
  its menu entries word for word, the view and control tooltips
  included; `harness-ui-server-test` holds the server page's buttons,
  tooltips and menu; `harness-ui-workspace-test` holds the workspace
  computer bar's eight labels and their eight tooltips, and the graph's
  `Back` and `Workspace` tooltips; `harness-ui-voice-live-test` holds
  `[Show details]` and `[Hide details]`; the Flutter tests
  (`computers_test.dart`, `computers_screenshots_test.dart`,
  `resources_screen_test.dart`, `task_drag_test.dart`,
  `task_actions_widget_test.dart`) hold the app's; the completion
  dialog's test holds `Mark done` and the absence of `Completion`.

## What was deliberately not changed

- **Headings, states and labels**: `Ready for review`, `Your input`,
  `Connected`, `Not registered`, `Verification required · finished work
  waits`, `Verification failure: ...`.  These name a state or an outcome.
- **Navigation**: `[Computers]`, `[Settings]`, `[Session list]`,
  `[Module list]`, `[Review Changes]`, `[Connection...]`, `[Threads]`,
  `[Diff]`, `[History]`.
- **The board's keys and commands**: only the words a person reads
  changed; every command, key binding and handler is untouched.
