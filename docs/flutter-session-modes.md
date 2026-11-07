# Flutter session modes

How the Flutter app learns that a conversation can change its permission
mode, what it offers, and why that is not extension discovery.

## The report

On the native desktop app, the permission-mode picker under a conversation
was stuck on *Ask*: the shield showed the mode, but tapping it did nothing,
and the session menu had no *Permission mode* entry. The harness server
offered all four modes and answered `session/set_mode`; the app never asked.

## Root causes

1. **A standard ACP method asked of extension discovery.**
   `HarnessCapabilities.setMode` was `has('session/set_mode')`, and
   `methods` is `initialize`'s `_harness.methods`. That object is
   `harness-acp--extension-methods`: the *bus methods* a client may call as
   `_harness/NAME`. `session/set_mode` and `session/set_model` are standard
   ACP handlers (`harness-acp--define-standard`), so they are never in that
   list. The capability was false for every real harness (the same mistake
   was in `setModel`, whose picker happened not to be gated on it). Reading
   the live server showed `session/update` advertised and
   `session/set_mode` absent — as designed.

2. **The session's mode state was discarded.**
   ACP carries modes in a `SessionModeState` (`currentModeId`,
   `availableModes`) on the answers of `session/new` and `session/load`,
   and announces later changes as `current_mode_update`. The app dropped
   `session/load`'s answer, and the harness's `session/load` answered `{}`
   instead of its modes. `current_mode_update` only refreshed the harness's
   richer session record (`session/get`), which a plain ACP agent does not
   have. So even an enabled picker would have had no modes to offer and no
   current mode to show on a standard-only session; the label *Ask* came
   from the harness's `permissionMode` field, which is why it looked alive.

## The decision

Standard ACP support is session state, not an advertised extension.

- `_harness.methods` stays exactly what the harness says its bus methods
  are. Standard names are not injected into it: doing so would make
  `has()` lie, and would claim methods an agent does not implement.
- The wrong `HarnessCapabilities.setMode` / `setModel` getters are gone.
- `SessionController.modes` takes the `modes` object of `session/new` and
  `session/load` (`SessionModes`, `SessionMode`) and follows
  `current_mode_update`. `canChangeMode` is true when the session is not
  one of the harness's virtual pages and the agent listed at least one
  mode. The footer picker and the session menu's *Permission mode* entry
  are both gated on it; the picker's items are the agent's own
  `availableModes`, labelled by their `name`.
- The harness's `session/load` now answers with
  `harness-acp--modes-plist`, as `session/new` always did. That is the ACP
  `LoadSessionResponse.modes` field, so an existing conversation — not just
  a newly created one — has the modes it can switch between.
- `SessionController.setMode` sends standard `session/set_mode` and shows
  the chosen mode only after the agent accepted it. A refusal leaves the
  mode as it was and reports the agent's error. A later
  `current_mode_update` is the authority and can name a mode another client
  chose.
- A session without modes (a plain agent that offers none, or a virtual
  page) still shows the mode it reports, but as text: no picker, no menu
  entry, no failed call.

## Copy

The only authored string is the existing noun phrase *Permission mode*.
Item labels are the agent's mode names (*Ask*, *Accept edits*, *Auto*,
*YOLO* for the harness); the old sentence-long labels ("Ask · reads
allowed, …") are gone. Failure copy is the existing error banner, carrying
the agent's own message as data.

## Alternatives

- **Add the standard methods to `_harness.methods`.** Rejected: that list
  describes bus extensions, and a client that trusted it would advertise
  `session/set_mode` on agents that have no such handler. The server's
  protocol test asserts `_harness.methods` stays extension-only.
- **Enable the picker for every session and let the call fail.** Rejected:
  an agent that offers no modes has nothing to choose, and a failed call is
  a worse answer than no picker.
- **Hardcode the harness's four modes in the app.** Rejected: it would not
  follow what the session says it offers, and duplicates server data.
- **Clear the modes when `session/load` omits them.** Rejected for now: an
  agent that sends modes on creation and not on load would lose a valid
  choice; absent modes leave what is known alone.

## Verification

- `harness_client/test/session_modes_test.dart`: a realistic `initialize`
  with no `session/set_mode` in `_harness.methods`; modes retained from
  `session/load`; a chosen mode calls `session/set_mode` and shows;
  repetition; a refusal; an agent's own `current_mode_update`; force
  reopen; a plain ACP agent; no modes; a virtual session; a new session's
  creation modes; the picker and session menu at 1440×900 and 390×844,
  with exact labels.
- `harness_client/test/session_modes_screenshots_test.dart`: real-font
  pictures of the picker and the open sheet on desktop and phone.
- `test/harness-acp-test.el`: `session/load` answers the current mode and
  every available mode, and the existing replay/extension tests still hold.
