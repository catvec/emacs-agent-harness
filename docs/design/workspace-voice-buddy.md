# The workspace voice buddy: the call view, the in-call bar and the away card

Design note, November 2026.  **Implemented in the Flutter client.**  This
page is the design for a workspace's live voice call on a desktop and a
phone: one call, the full view that belongs to it, a bar at the top of the
app for as long as it runs, and -- on a desktop, opt-in, when the window is
not the one in use -- a compact away card.  It reuses the voice stack and
the workspace client that already exist; it adds no second microphone and
no second call.  On a desktop the away card is a window of its own: it is
the same Flutter engine and the same controller, drawn over the app and
left on screen when it is clicked.  It adds no tray icon and no shortcut.

The first slice put one compact card in the corner of the app and used it
for every call, whether the app was in use or not.  Review made the shape
of the feature clearer: a call's main surface is in the app, the app tells
the person at the top that a call is running, and the compact card is for
when the app is *not* the window they are working in.  This note is the
design after that change.

Related contracts:

- [Workspace mode](../workspace-mode.md) and its
  [implementation design](../workspace-mode-implementation.md), whose
  `Call` action attaches a call to a thread's live episode.  That work
  (the OpenClaw-shaped workspace chat, task `t-ies2341h`) and this one
  share the call target; this page does not replace the workspace.
- [Realtime voice](../voice-realtime.md), especially **UI states**
  (lines 344–372): `Off`, `Starting`, `Listening`, `Hearing you`,
  `Transcribing`, `Working`, `Holding reply`, `Speaking`, `Interrupted`,
  `Muted`, `Ending`, `Failed`; microphone on/off and `End` are
  mandatory, `Interrupt` is reachable without a keyboard, and
  `Speaking` follows the player rather than generation.
- [Voice turn-taking](../voice-turn-taking.md), whose output gate
  (`Holding reply`), pause/mute/interrupt/end controls and start/stop
  transitions this page applies unchanged (task `t-595zkjeu`).  The bar,
  the call view and the away card are three views of one
  `VoiceController`, not a new turn-taking implementation.
- [The client's voice mode](../../harness_client/README.md#voice-mode),
  the live/clip backends, `VoiceController`, `SessionVoiceBridge` and the
  full `VoiceScreen`.  All of those stay the only audio path.

## The problem

A call used to be a full screen, and leaving that screen ended it.  A
desktop user who wanted to look at the workspace, a task or a conversation
had to choose between the call and everything else.  The first slice made
a compact card available in the corner, but the card was on screen while
the app was focused too, over the very pages it was meant to keep within
reach.  On a phone, a call had no presence at all outside the full screen.

The call itself is not a page.  It is a piece of state attached to a
workspace and a thread, and it needs a surface at every moment that the
person can see it: the large view while they are in it, a bar while they
are using the app, and, on a desktop away from the window, a compact card
that says the same thing in less room.

## The three surfaces of one call

There is one call per selected workspace.  `WorkspaceBuddyController`
still owns it: at most one `VoiceController`, the existing
`SessionVoiceBridge` and the guarded start/end lifecycle.  The surfaces
below are views of that one call.  None of them starts a second one.

### The call view

`VoiceScreen` is the large surface: the orb, the transcript, settings,
mute, pause, interrupt and End.  It can be opened *attached* to a call
that belongs to the workspace:

- opening it from the workspace's `Call`, from the in-call bar or from the
  away card does not start a new call;
- closing it with the chevron, Escape or the platform back gesture
  **minimizes** the call; it does not end it;
- its `End` goes back through the workspace controller, which stops the
  microphone, the player and the provider connection, and then closes the
  view;
- it never starts, stops or disposes the controller it shows.  If the
  call ends or is lost while the view is open, the view leaves; the
  controller is kept until the next call so a view can always remove its
  listener.

### The in-call bar

A single bar at the top of the app, above every page and every route,
on every width from a phone to a wide desktop, for as long as the call
needs a surface:

- `In a call`, then the workspace's name and, on a wide screen, the
  thread the call is pinned to;
- the status the backend reports (`Listening`, `Hearing you`, …) and
  the microphone line (`Mic live`, `Mic muted`, …), each a live region;
- `Mute`/`Unmute`, `End`, `Retry` when the call reports a retryable
  problem, and `Call view` to open the large view;
- the identity is a button to the same view, so a phone can open it by
  tapping the bar.

The bar is the call's persistent, in-app presence.  It is not opt-in:
while a call runs, the person can see its microphone and end it from any
page.  It leaves the top of the screen when the call ends or when the
call view is the surface showing it.  It stays when the away card is
also on screen: the card is an extra, compact presence in the same
window, not a replacement for the call's controls.  The pages under it
keep their normal top safe area; while the bar is there the app reserves
its height above the navigator, and the status bar is part of the bar, not
repeated under it.

### The away card

The compact card is the desktop's away surface, and it is the part the
workspace opts into (see **Workspace-scoped opt-in**).  It is a call's
surface: it shows only while the workspace has a call (starting, running,
failed or ending), the app's main window is **not active** -- behind
another window, or reporting `hidden`/`paused` -- and there is no call view
on top of it.  Opting a workspace in starts no call and draws no card; the
card appears when a call starts, and a failed call keeps it so its problem
and `Retry` stay in sight.
While the main window is the one in use, the card is not shown; the bar
and the call view are the call's surfaces.  When the window is away the
bar stays as well, so a call over a pushed page is never without its
microphone line and `End`.  On a phone the card is never shown.

The card keeps the first slice's content and behaviour: workspace and
thread identity, the connection, the reported status, the microphone
line and level meter, `Start`/`End`, `Mute`/`Unmute`, `Pause`/`Resume`,
`Interrupt`, `Voice settings`, `Retry` and its own `off` control.  It is
dragged by its header, does not take focus when it appears, and its close
control removes it without ending the call.

On a desktop the card is drawn in a **window of its own**: a frameless,
always-on-top window that is absent from the taskbar and **does not
activate**, so pressing a control or dragging its header neither brings
the app forward nor makes the card disappear.  This is the fix for the
first version's blindness to its own clicks: the card was in the app's
window and the away rule removed it the moment clicking it made that
window active.  The window is a second view of the same Flutter engine
and the same `WorkspaceBuddyController` -- not a second engine, a second
call or a copy of the state.  It is placed at the bottom-right of the
primary display's work area on first show and keeps wherever it is
dragged to afterwards.  A compositor that activates the window on a click
anyway does not bring the card back under the away rule: while the card's
window is the active one, the main window is still not the one in use, so
the card stays; it hides when activation goes back to the main window.

A platform that cannot open a window -- the web, or a compositor that
refuses one -- gets the **persistent in-app card** instead.  That card
stays on screen while the buddy is on and the workspace has a call, not
only while the window is away, because an away-only in-app card cannot be clicked: the
click focuses the app, and the card would go before the click arrives.
A window that fails to open falls back to the persistent card for the
rest of the run; a window the compositor destroys is made again the next
time it is wanted.  The `HARNESS_BUDDY_WINDOW=off` environment variable
forces the fallback on a machine whose compositor cannot draw a
non-activating window.

### The Linux window

The decisions that produced this window, and the failures they answer,
are in [buddy-window-fixes.md](buddy-window-fixes.md).

On Linux the card's window is the `GtkWindow` Flutter's windowing API
makes, handled through GTK directly
(`lib/src/desktop/buddy_window_linux.dart`) because the windowing API
exposes no frame, size or stacking policy of its own.  Three things are
set there, and each answers one of the reported failures of the first
native window:

- **Frame.**  The window gets a client-side titlebar with zero height and
  no controls, so GTK draws the window and the window manager adds no
  title bar or top bar of its own.  The card's surface reaches every
  edge; the small GTK shadow around a client-side frame stays, which is
  what a floating card wants.  On X11 the same client-side decoration
  keeps the window manager's frame off.
- **Size.**  The window is opened at the card's fixed width and a
  provisional height of 120 px.  The card is laid out without a height
  limit, measured after layout and reported back through
  `BuddyWindowService.reportContentSize`; the window is then made that
  height, bounded to 120–720 px.  A running card, and the taller card of
  a failed call with its problem and `Retry`, are shown whole instead of
  being clipped by a height chosen before the first frame.  Content
  taller than the maximum scrolls inside the card's own scroll view
  rather than overflowing the window.
- **Stacking and placement.**  On X11, `gtk_window_set_keep_above` is
  honoured, as are the skip-taskbar and non-activating hints, and the
  window is placed at the bottom-right of the primary monitor's work
  area.  A Wayland compositor has no client request for keep-above, and
  GTK's property is ignored there; the compositor also places the window
  itself.  Plasma gets the missing properties from a small KWin script
  loaded over D-Bus (`lib/src/desktop/plasma_window_rules.dart`), which
  matches only this app's pid and the window caption `Buddy` and sets
  `keepAbove`, `skipTaskbar` and `noBorder`; the script is unloaded when
  the card is disposed.  Other Wayland compositors keep the card as a
  normal non-activating window: above the other windows at the moment it
  is shown, but not guaranteed to stay there (see **Limits**).

### Minimized and unfocused

A desktop window that is **unfocused but visible** reports
`AppLifecycleState.inactive`; the away card appears beside the bar.  A
window that is **minimized** reports `hidden` (and then `paused`); the
main window draws nothing, but the away card is a top-level window of its
own and is not minimized with the main one.  The call keeps its identity
and its state and the OS's own microphone indicator stays on; the card
is the surface that stays in sight, and the in-call bar -- with `Mic
live` and `End` -- is there the moment the main window is shown again.
Whether the engine keeps painting the small window while the main one is
minimized is the platform's business; the fallback card, being in the
main window, cannot be drawn there at all.

The window is still a surface of this app and obeys the same rule: it is
shown only while the buddy is on, the workspace has a call, and the main
window is not in use.  It does not take `alwaysOnTop` from the rest of the app, a tray
icon, a global shortcut or a startup item.

## Research: desktop surface patterns

The call's full view and bar stay in the app's window.  The away card
was first drawn there as well; the review of that slice found the limit
the person hit: clicking an in-app card focuses the app, the away
rule then removes the card, and a drag cannot finish.  The card is now a
separate native window where the platform has one, and remains an in-app
card only as the fallback where it cannot have one.  The call view and
the bar are still not windows, and no surface starts a second call.

| Pattern | What it gives | Cost / limit | Sources |
| --- | --- | --- | --- |
| **In-app surfaces** (fallback; the call's full view and bar) | A full view, a bar and, where no native window is possible, a persistent card in the app's own window; no new permission or plugin; keyboard focus, semantics and theming work as everywhere else; drag and clamp inside the window | Only visible while the app is; cannot float above other applications or paint while minimized; an away-only card cannot be clicked without hiding itself | Flutter's desktop support and `Stack`/`Overlay` APIs |
| **Native always-on-top window, same engine** (this design for the away card) | Stays above other apps where the platform honours it; skips the taskbar; has no title bar; does not activate when clicked or dragged; the same engine and `WorkspaceBuddyController` keep the card and the call in one state | A native window level, focus and close lifecycle per OS; always-on-top is a request the compositor may ignore (notably on Wayland; Plasma gets it through KWin's own scripting); the window is non-focusable, so its card is pointer-only and keyboard access stays in the bar and call view | Flutter's windowing API (`RegularWindowController`, experimental), `nativeapi` window properties, GTK 3 (`gtk_window_set_titlebar`, `gtk_window_resize`), KWin scripting |
| **Native window through `window_manager` alone** | Window levels, `alwaysOnTop`, `skipTaskbar` for the main window | It manages one window; a second window needs Flutter's windowing API or a multi-window package anyway | `window_manager` |
| **System tray / menu bar extra** (`tray_manager`) | A tiny persistent icon with a menu | Not consistently available (`tray_manager` documents that GNOME shows no icon without the AppIndicator extension); a menu is poor for a live microphone indicator and an urgent End; Microsoft's own notification-area guidance says the area is not for quick command access or critical information | `tray_manager`; Microsoft "Notifications and the Notification Area" |
| **Separate small window** (`desktop_multi_window`) | A real second window, can be placed by the window manager | Each window is a Flutter engine with its own plugin registration and method channels; the same app state and voice controller do not cross engines without a bridge; more OS integration and permissions than the feature needs | `desktop_multi_window` |
| **Bottom sheet / dialog inside a page** | Simple | Takes the screen or blocks the page; not a persistent presence; cannot stay while the user reads another page | Material/Flutter conventions; the app already uses sheets for focused tasks |
| **PWA / browser Picture-in-Picture** | A floating browser window | Not applicable to the native Flutter client; needs a user gesture and browser support; no shared controller with the app | Document Picture-in-Picture API |

## Workspace-scoped opt-in

- The choice is stored per workspace id in the device's preferences
  (`workspaceBuddies`, a string list), next to the existing voice
  settings.  It is the device's, like the voice provider: two devices may
  choose differently and signing out does not forget it.
- The workspace page's desktop header has a `Buddy` action.  Its
  tooltip is `Workspace buddy · on` or `Workspace buddy · off`, and it
  is a toggle.  It opts the workspace into the **away card** only.  It is
  offered only where the card can be drawn (desktop width, workspace
  loaded); a phone keeps the in-call bar and never shows the card.
- The workspace's `Call` action is offered whenever the active thread has
  a live episode, whatever the opt-in.  It starts the workspace call (or
  opens the view of the call already running) and opens the call view.
  With a call running, the bar is its persistent surface.
- Turning the buddy on restores the away card after a restart but does
  **not** start a call.  Turning it off persists the opt-out and removes
  the card.  It does **not** end a running call: the call is the bar's
  and the call view's, and both keep the microphone state and `End` in
  sight.  The card's own `off` control does the same.  `End` is the
  control that ends a call.  A preference store that does not open or
  refuses the write leaves the in-memory choice working for this run; the
  app does not fail to start and the existing persistence notice remains
  the place that says the store is broken.
- If the selected workspace changes, a call is ended before the bar and
  the card rebind; if the workspace capability disappears, the buddy
  controller is disposed.  A call is always pinned to the workspace,
  thread and live session it started on, and the surfaces show those, not
  a later selection.

## Lifecycle and races

One `WorkspaceBuddyController` owns at most one `VoiceController`:

```text
no call ──Call/Start──▶ starting ──backend started──▶ listening/hearing/…
    ▲                      │                              │
    │                      └──── End (cancels opening) ───┤
    └──────── End / connection lost / workspace change ───┘
```

- **One call.**  A second Start while starting or running is ignored; a
  double tap cannot open a second backend or a second session.  A second
  surface opening the view is the same controller, not a second call.
- **Minimize vs End.**  Leaving the call view pops it and changes
  nothing about the call; End stops the microphone, the provider
  connection and held output, and then the view goes.  The agent's work
  keeps running as `VoiceScreen`'s End always did.
- **End during start.**  Start captures a generation, opens the session
  bridge, creates the controller and starts the backend.  End increments
  the generation, stops and retires the controller.  The voice controller
  itself also gets a lifecycle generation: a backend that finishes opening
  after a stop is closed at once, so the microphone cannot be left open
  after End.
- **End during capture, transcription, thinking, speaking or a prompt
  send.**  `VoiceController.stop()` cancels the backend subscription,
  calls the backend's `stop` (microphone, player and provider
  connection), clears held output and removes the session listeners.  A
  late event is dropped by the controller; no caption, prompt or speech is
  emitted after End.
- **Unexpected end.**  A voice backend's own ended event while the buddy
  did not ask to end is treated as a lost call: the controller is stopped
  and retired, the bar goes, the card shows `Call lost` when it is the
  surface, and Start is available again.
- **Connection lost / reconnecting.**  When the app loses the harness
  connection, the call is ended immediately (microphone first), the host's
  `Reconnecting` state is shown, and `Connection lost` is the card's note.
  The call is not resumed when the connection returns; Start is an
  explicit action.  A harness connection is required to start.
- **Errors and permission denied.**  The controller's problem label is
  shown as data (`Microphone permission denied`, `Microphone
  unavailable`, `Transcription failed`, `Live connection failed`, …) in
  the card and the call view, with its detail and a `Retry` control.  The
  bar shows `Failed`, `Mic off` and a `Retry` control when the call has
  one, and the call view has the problem in full.  Nothing asks for a
  permission ahead of Start; the existing backend asks the OS when the
  call opens.
- **Turn off / hide the card.**  The card's `off` control and the
  workspace action remove the card; a running call stays in the bar (or
  the call view) with its microphone and End, so nothing is left recording
  behind a hidden card.  There is no hidden-call state.
- **Narrowed under the breakpoint.**  The card is built only at the
  desktop breakpoint (920 px).  Below it the card is not built and the
  call is not ended: the in-call bar is the surface at every width, with
  the microphone line and End.  The workspace page's `Call` opens the same
  call's view instead of a second one.
- **Window focus.**  The app records whether its main window is the one
  in use (`AppLifecycleState.resumed`).  A desktop that is not active also
  gets the away card, in its own non-activating window; when the app is
  active again the card is hidden, not destroyed.  Clicking or dragging
  the card does not change the app's lifecycle, so the card does not take
  itself away.  The bar is there in both cases.  The call itself is
  untouched by the change; no surface starts or stops it on a focus
  change.  A platform with no native window shows the persistent in-app
  card while the buddy is on and the workspace has a call, because there is
  no other way to click it.
- **Disposal.**  Closing the app, losing the workspace or the shell
  disposing the controller removes the listeners and closes the voice
  controller, which releases the microphone.  Stopped controllers are kept
  until the next call so a view that is still on screen can remove its
  listener, and are disposed then.

## Compact surface and copy inventory

Every authored string is a noun, a noun phrase or an adjective; provider
and error details are data.  The bar's icon controls carry accessible
names and semantics tooltips rather than hover popups; the card and the
full call view keep their hover tooltips.

| Place | Copy |
| --- | --- |
| Call view title | `Voice` |
| Call view close (attached) | tooltip `Minimize` |
| Call view close (own call) | tooltip `End` |
| Bar heading | `In a call` |
| Bar identity | the workspace's name (`Home`), the thread's title on wide (`Kitchen renovation`) |
| Bar identity action | `Call · view` (label and tooltip) |
| Bar connection? | no: the bar is only for a call; the card carries `Connected` / `Reconnecting` / `Offline` |
| Status (exact) | `Off`, `Starting`, `Listening`, `Hearing you`, `Transcribing`, `Working`, `Holding reply`, `Speaking`, `Interrupted`, `Muted`, `Paused`, `Approval needed`, `Ending`, `Ended`, `Failed`, `Status unknown` |
| Semantics of the status | `Status · <label>` (live region) |
| Microphone | `Mic live` / `Mic muted` / `Mic paused` / `Mic starting` / `Mic closing` / `Mic off` |
| Semantics of the microphone | the microphone line itself (live region) |
| Bar primary controls | `End`; semantics tooltip `Call · end` |
| Bar secondary controls | `Mute` / `Unmute`, semantics tooltip `Microphone · <microphone state>`; `Call view`, semantics tooltip `Call · view`; `Retry`, semantics tooltip `Call · retry` |
| Microphone control tooltip | `Microphone · live`, `Microphone · muted`, `Microphone · starting`, `Microphone · paused`, `Microphone · closing` or `Microphone · off`, from `BuddyMic` and not from the phase |
| Card heading | `Buddy` |
| Native window title | `Buddy` (the same word as the heading; the window is frameless where the platform allows) |
| Semantics of the card | `Workspace buddy` |
| Card connection pill | `Connected` / `Reconnecting` / `Offline` |
| Connection tooltip | `Connection · <address>` (address is data) |
| Provider | `Clip` / `Live` (the existing voice provider labels) |
| Card status | the same status labels as the bar |
| Card microphone | the same microphone labels as the bar |
| Level meter tooltip | `Microphone · level` (only when the backend reports levels and the microphone is live) |
| Concurrent activity | `Speaking`, `Reply held`, `Working` when one of those is not already the status and the state is real |
| Card primary controls | `Start`, `End` |
| Card secondary controls | `Mute` / `Unmute`, `Pause` / `Resume`, `Interrupt`, `Voice settings` |
| Problem control | `Retry`; tooltip `Call · retry` |
| Card off control | `Buddy · off` (tooltip and accessibility label `Workspace buddy off`) |
| Workspace open | `Workspace · open` |
| Workspace action | `Buddy`; tooltip `Workspace buddy · on` / `Workspace buddy · off` |
| Workspace action | `Call` (opens the call, or the running call's view) |
| Start tooltip | `Call · start` |
| End tooltip | `Call · end` |
| Mute tooltip | the same `Microphone · <microphone state>` as the bar, so a failed or starting call never says `Microphone · live` |
| Pause tooltip | `Conversation · live` / `Conversation · paused` |
| Interrupt tooltip | `Playback · interruption` |
| Settings tooltip | `Voice settings` |
| No live episode | `No live episode` |
| Voice not configured | `Voice setup` |
| Lost call | `Call lost` |
| Lost connection | `Connection lost` |
| Unknown | `Status unknown` |

No sentence is authored for any surface.  Error labels and details are
the backend's own words, shown as data; the voice settings sheet keeps its
existing explanatory setting descriptions.

Layout: the bar is 56 px high on a phone and 60 px on a wide screen,
growing by a bounded amount (up to 80 px) when the text does; it takes
the status bar into its own top padding, and the pages below lose that
padding while it is shown.  The card is 312 px wide and grows by a
bounded amount with the text scale.  In its own window it is placed
bottom-right of the primary display's work area, draggable by its header,
and sized to its content; the fallback card is anchored bottom-right by
default, draggable by its header and clamped inside the app's window.  At
920 px it fits beside the page; at 1024, 1280 and 1440 it is a corner
surface, not a page.  On a phone the card is not built at all; the bar is.

### Controls and their meaning

- `Start` (card) starts a new call on the active thread's live session.
- `Call` (workspace) starts the same workspace call and opens its view;
  with a call already open it opens that call's view.
- `End` (bar, card and call view) ends the call: microphone, provider
  connection and held output.  It never cancels the agent's work; the
  session keeps running as `VoiceScreen`'s End does.
- `Minimize` (the call view's chevron) leaves the view and keeps the call
  in the bar.  It is not End.
- `Interrupt` stops playback only.  It is the separate action from
  cancelling work, and work is cancelled from the conversation's own
  Stop, not from these surfaces.
- `Pause`/`Resume` follow the existing controller: capture and provider
  audio stop and no held output is replayed.
- `Mute`/`Unmute` close or open capture; the indicator and status say
  `Muted` and `Mic muted`.
- `Voice settings` opens the existing sheet; a change is saved and, if a
  call is running, applied through `VoiceController.updateSettings`.
- `Retry` starts a new call after a failure, through the same guarded
  Start path.
- `off` (card) removes the away card and keeps the opt-in off; it does not
  end the call the bar shows.

## State mapping: actual events to surfaces

This is the contract.  "Actual" means reported by the voice backend or
the app; nothing is inferred from time, silence or a spinner.  The bar
and the card use the same `BuddyViewModel`; the call view uses the same
`VoiceController`.

| Source (actual) | Bar and card |
| --- | --- |
| No `VoiceController` (off, ended and retired) | Bar not shown; card `Off`; `Mic off`; Start enabled when the workspace thread has a live episode and the app is connected |
| `VoicePhase.connecting` (backend start) | `Starting`; `Mic starting` while the microphone opens; Start disabled, End enabled |
| `VoicePhase.listening` (backend reports capture listening) | `Listening`; `Mic live` |
| `VoiceSpeechEvent(true)` or `VoicePhase.hearing` | `Hearing you`; `Mic live`; a held or speaking output chip if that is also true (card) |
| `VoicePhase.transcribing` (clip transcription) | `Transcribing`; `Mic live` |
| `VoicePhase.thinking` or the session bridge's `working` | `Working`; `Mic live` unless muted/paused/off |
| `VoiceController.holdingReply` (held assistant output) | `Holding reply`; `Reply held` when it is not already the status (card) |
| `VoicePhase.speaking` (the backend's player/response state) | `Speaking`; `Mic live` (input and output may both be live) |
| `VoicePhase.interrupted` | `Interrupted` |
| `VoicePhase.muted` / `VoiceController.muted` | `Muted`; `Mic muted`; no level meter |
| `VoiceController.paused` | `Paused`; `Mic paused`; no level meter |
| Session bridge `blocked` (permission or question) | `Approval needed`; the conversation remains the place to answer |
| `VoiceController.stopping` | `Ending`; `Mic closing` |
| `VoiceController.problem` fatal / `VoicePhase.failed` | `Failed`; the problem label and detail (card and call view); `Mic off`; `Retry` in the card and bar; `End` dismisses the failed controller |
| `VoiceController.problem` recoverable | the phase's status, plus the problem label/detail and `Retry` (card and call view) |
| `VoiceLevelEvent` | the card's meter level; the meter exists only after a level was actually reported and only while `Mic live` |
| App connection `connected` / `reconnecting` / other | the card's `Connected` / `Reconnecting` / `Offline`; the bar is shown only with a call |
| App connection lost while running | the call is ended; `Connection lost` (card); `Mic off`; Start waits for `Connected` |
| Voice backend ended without a user End | `Call lost` (card); the controller is stopped and retired; `Mic off`; Start enabled |
| Unrecognised phase name from a live sidecar | `Status unknown` (the protocol reports it as `VoicePhase.unknown`) |
| Workspace thread without a live episode | `No live episode`; Start disabled |
| Voice settings not configured | `Voice setup`; Start disabled; Settings available |

Precedence mirrors `harness-voice-live--status` (see
[voice-realtime.md](../voice-realtime.md#ui-states)) so the clients
say the same word for the same state: failure, starting, ending,
interrupted, hearing/transcribing/working, speaking, holding reply,
working, muted, listening.  The app-only states (`Paused`,
`Approval needed`, `Ended`, `Status unknown`) are placed where their
actual meaning demands: `Paused` before capture states, `Approval
needed` before progress states, `Ended` only after an ended controller.

### What the UI must not claim

- There is **no transfer or transcoding stage** in the current APIs.
  `VoicePhase` has `transcribing` (speech-to-text) and `thinking`
  (agent work), the live protocol has no byte-progress event, and the
  clip backend's audio upload is one awaited request with no progress
  event.  The surfaces therefore render `Transcribing` only when the
  clip backend reports it, and never show `Uploading`, `Transferring`,
  `Transcoding` or a progress bar for bytes.  A future sidecar that
  reports such a stage would have to be added to the protocol and this
  mapping first; an unknown phase is shown as `Status unknown`, not
  guessed.
- `Listening` and `Hearing you` are shown only from the backend's
  phase or speech event.  A generated waveform or a spinner is not
  evidence of either.
- `Mic live` and the card's level meter are shown only when the
  microphone is actually held open by the call (running, not muted, not
  paused, not ending).  Muted, paused, ending, failed and off say so and
  show no meter.  Idle or muted is never drawn as recording, uploading or
  sending.
- `Speaking` follows the provider's player state, not the generation
  of an answer, as the voice contract requires.
- `Holding reply` appears only when assistant output is actually held;
  the card does not announce a queue it does not have.

## Privacy and accessibility

- A call in progress is visible at all times the app can be seen: the bar
  says `In a call` above every page, with the microphone line and `End`,
  on a phone too.  The card appears when the main window is not in use,
  still with the microphone line.  The separate card window is drawn by
  the compositor when the main window is minimized or another app is in
  use; the main window's own surfaces are not, and a locked screen is not
  drawn by the app.  The OS's own microphone indicator remains the
  indicator in every case.
- The surfaces show a textual microphone state and a distinct icon as
  well as colour: `Mic live` versus `Mic muted` versus `Mic off`.  Colour
  is never the only cue.  The pattern follows the platform privacy
  indicators ([Android privacy indicators](https://source.android.com/docs/core/permissions/privacy-indicators),
  [Apple's orange indicator](https://support.apple.com/en-us/108331))
  and established voice-device states ([Alexa light ring](https://developer.amazon.com/en-US/alexa/branding/alexa-guidelines/brand-guidelines/light-ring):
  listening, thinking, responding, mic muted, error).
- Every control has an accessible label, a tooltip or semantics tooltip
  where it applies, and `enabled` / `toggled` semantics where it applies.
  The status and microphone lines are live regions so a screen reader
  announces changes without taking focus ([WCAG 4.1.3](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html),
  [Flutter accessibility](https://docs.flutter.dev/ui/accessibility)).
  The bar's icon-only controls are named `Mute`/`Unmute`, `End`,
  `Call view` and `Retry`; its identity is a `Call · view` button.
- Keyboard: the bar is in the normal focus traversal above the pages;
  `Tab` reaches its identity and controls, and `Enter`/`Space` activate a
  focused control.  The call view keeps its own `M`, `P`, `E` and
  `Escape` bindings; in an attached view `Escape` minimizes and `E` ends.
  The native buddy window is deliberately non-focusable, because a window
  that took focus would make the app active and the card would be hidden;
  its card is pointer-operated.  Nothing is keyboard-only lost: while a
  call runs, the bar offers the identity, `Mute`/`Unmute`, `End`,
  `Retry` and `Call view`; the call view has `Pause`, `Interrupt`, `Voice
  settings` and End, and the workspace's `Call` starts a call.  The
  fallback in-app card is in the traversal when it is on screen.  A
  visible control is reachable without a keyboard in the call view
  ([WCAG 2.1.1 Keyboard](https://www.w3.org/TR/WCAG22/#keyboard),
  [2.4.7 Focus Visible](https://www.w3.org/TR/WCAG22/#focus-visible).)
- Reduced motion: the card's status transition uses `Duration.zero` when
  `MediaQuery.disableAnimations` is set and the card has no repeating
  animation; the bar's status switches in `Duration.zero` under the same
  setting and the bar itself does not animate.  The level meter is a
  static drawing of the last reported level
  ([Flutter `disableAnimations`](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html),
  [WCAG 2.3.3](https://www.w3.org/TR/WCAG22/#animation-from-interactions)).
- The bar does not steal focus when a call starts; the card does not steal
  focus when it appears; neither covers the whole page.
- The provider (`Clip` / `Live`) is a configuration fact, not a live
  transfer readout.  Audio destination and retention are the existing
  voice settings' and docs' subject, not invented here.

## Testing plan

Deterministic, with scripted audio only:

- **Pure mapping:** every status label, precedence, microphone state,
  unknown phase, simultaneous input/output, no transfer labels.
- **Controller:** opt-in/out and restore; one call at a time; double
  Start; End during Start (opened backend closed); End during capture,
  transcription, thinking, speaking and a prompt send; repeated
  start/stop; unexpected ended; disconnect during a call; workspace
  change; dispose; no emitted prompt/speech/caption after End; turning
  the opt-in off keeps a running call; the call has a surface from
  Starting until End; the call view flag.
- **Call view:** attached mode does not start, stop or dispose the
  controller; the close tooltip is `Minimize` and popping does not stop
  the call; `End` pops and goes through the owner; an attached view does
  not show the standalone `End` tooltip on its close.
- **Bar:** exact rendered copy and semantics for every state; status and
  microphone live regions; `End`, `Mute`/`Unmute`, `Call view`, `Retry`
  and the identity; no call view while Starting with no controller;
  phone and desktop widths at 100%, 150% and 200% text; reduced motion;
  no sentences and no invented stages.
- **Away card:** exact rendered copy and tooltips for every state; live
  region labels; toggled/enabled semantics and the focus action; focus
  order and Enter; loading/empty/error/permission-denied states; reduced
  motion; 920, 1024, 1280 and 1440 widths at 100%, 150% and 200% text;
  no card on opting in alone, and none on a phone; no card while the
  window is active; narrowing the window leaves the call in the bar, not
  ended; off is not End.
- **Own window:** the window is asked for only while the workspace has a
  call, the buddy is on, the main window is away, no call view is open and
  the width is a desktop one; opting in with no call opens no window and
  draws no card; it is hidden, not destroyed, when the app comes forward; the
  same `WorkspaceBuddyController` is behind the card and the call; the
  card's measured height is reported back and a taller card grows the
  window, while content beyond the maximum scrolls; the window content
  drags the native window instead of a card; a window that cannot open
  leaves the persistent in-app card, and that card stays on screen while
  the app is in use and can be dragged; the workspace action brings the
  app forward on its workspace page.  The widget-test engine cannot open
  a native window: a fake service tests the seam, the Linux build compiles
  the real one, and `tool/buddy_window_probe.dart` draws the real card in
  the real window for a compositor to be observed.
- **Window rules:** the KWin script names this app's pid and the `Buddy`
  caption and sets keep-above, skip-taskbar and no-border; a caption is
  escaped as a JavaScript string.
- **Integration:** a desktop opts in and sees the card only when the
  workspace has a call and the window is away; a phone keeps `Call` and gets the bar when
  the call view is minimized; the view is the same call (one backend);
  the bar stays and the card appears on focus loss and goes on focus;
  narrowing leaves the bar; `End` in the bar ends the call.
- **Screenshots:** the real widgets with a scripted backend: the desktop
  in-call bar, the phone in-call bar, the away card, 150% text, reduced
  motion and a failure.  The README labels them as scripted/backend-only.
  No real microphone, speaker, device, provider key or OS window is
  exercised by those.  The window itself was captured by the probe from
  its own layer tree under a nested KWin session, and the window
  properties were read back from KWin in the same runs: see
  [the evidence](../evidence/buddy-window/README.md).
- **Repository:** `flutter analyze`, the whole Flutter test suite,
  `scripts/test.sh`, `scripts/lint.sh`, and
  `harness_client/tool/check_build.sh` for the committed tree.

## Implemented slice

The surfaces are in the Flutter client, behind the workspace capability
and, for the away card, the per-workspace opt-in; no other client or
harness method changes.

| Area | What was added | Where |
| --- | --- | --- |
| Pure mapping | `BuddyPhase`, `BuddyMic`, `BuddyOutput`, `BuddyConnection`, `BuddyStatus`, `BuddyViewModel`, `buddyPhaseFor`, `buddyMicFor`, `buddyOutputFor`, `buddyStatusFor`, the shared phase icon and colour | `lib/src/voice/voice_buddy.dart`, `lib/src/ui/widgets/workspace_buddy.dart` |
| Controller | one `VoiceController`, opt-in/out, guarded Start, End during start, lost call, connection loss, workspace change, teardown, `inCall`, `callViewOpen`, retired controllers | `lib/src/state/workspace_buddy_controller.dart` |
| Voice controller | `stopping`, `levelReported`, `holdingReply`, `microphoneOpen`, a lifecycle generation that closes a backend opened after Stop, and the unknown phase | `lib/src/voice/voice_controller.dart`, `lib/src/voice/voice_models.dart`, `lib/src/voice/live_protocol.dart` |
| App host | the selected workspace and thread, connection, address, settings, session bridge and the per-workspace preference; the backend factory seam for tests; `windowActive` | `lib/src/state/app_controller.dart`, `lib/app.dart` |
| Bar | `WorkspaceCallBarHost`, `WorkspaceCallBar`, `WorkspaceCallBarView`, the visible predicate and `openWorkspaceCallView` | `lib/src/ui/widgets/workspace_call_bar.dart`, `lib/app.dart` |
| Call view | attached mode, `Minimize`, End through the owner, no dispose of the owner's controller | `lib/src/ui/screens/voice_screen.dart` |
| Away card | the card, its in-app drag-and-clamp layer, the away/focus rule, no narrow-width End | `lib/src/ui/widgets/workspace_buddy.dart`, `lib/src/ui/screens/home_shell.dart` |
| Own window | the service seam, the native window and the unsupported fallback; window view, placement and drag | `lib/src/desktop/buddy_window.dart`, `lib/src/desktop/buddy_window_native.dart`, `lib/src/desktop/buddy_window_unsupported.dart` |
| Linux window | the `GtkWindow` behind the window: zero-height client-side frame, non-activating and skip-taskbar hints, keep-above request, content-sized window, X11 placement and drag, bringing the app forward | `lib/src/desktop/buddy_window_linux.dart` |
| Plasma rules | the KWin script loaded over D-Bus that gives the Linux window keep-above, no taskbar entry and no border on a Plasma Wayland session, and is unloaded with the card | `lib/src/desktop/plasma_window_rules.dart` |
| Window host | when the window is wanted, the same controller, the card's measured height, the persistent fallback, the workspace tab request and the settings sheet from the window | `lib/src/ui/widgets/buddy_window_host.dart`, `lib/app.dart`, `lib/main.dart` |
| Workspace | `Call` starts or opens the shared call; `Buddy` opts into the away card | `lib/src/ui/screens/workspace_screen.dart` |
| Preference | `workspaceBuddies` read, written and restored per workspace id | `lib/src/state/settings_controller.dart` |
| Copy inventory regression | every rendered word, semantics label and tooltip; no sentences; no transfer or transcoding words | `test/workspace_call_bar_test.dart`, `test/workspace_buddy_widget_test.dart` |
| Mapping tests | every status, precedence, simultaneous input/output, microphone truth, unknown phase | `test/voice_buddy_test.dart` |
| Controller tests | opt-in/out, restore, double Start, End during start and every phase, prompt send, lost call, disconnect, workspace change, disposal, denial, Retry, off keeps the call | `test/workspace_buddy_controller_test.dart` |
| Integration | the bar on a phone, minimize, the same call, focus hand-over, narrowing, End, the away opt-in, no card before a call, the own window, its fallback and the workspace tab | `test/workspace_shell_test.dart`, `test/workspace_buddy_widget_test.dart`, `test/support/buddy_window_fakes.dart` |
| Window rules tests | the script's pid and caption match, the three properties, and caption escaping | `test/plasma_window_rules_test.dart` |
| Window probe | the real card in the real Linux window with a scripted call: frame, size, stacking and placement, `--failed` for the taller card | `tool/buddy_window_probe.dart` |
| Call view tests | attached minimize and End through the owner | `test/voice_ui_test.dart` |
| Preference tests | per-workspace write, restore and a choice made while the store is still being read | `test/settings_controller_test.dart` |
| Pictures | `workspace-call-bar-desktop`, `workspace-call-bar-phone`, `workspace-buddy-away`, `workspace-buddy-scale-150`, `workspace-buddy-problem`, `workspace-buddy-reduced-motion`, `workspace-phone` | `test/workspace_screenshots_test.dart`, `screenshots/` |

The pictures are drawn by the widgets with a scripted backend and the
real font; they are not photographs of a device.  The full checks are
`flutter analyze`, the Flutter test suite, `scripts/test.sh`,
`scripts/lint.sh` and `harness_client/tool/check_build.sh` for the
committed tree; the focused commands and their logs are in the hand-in
report.

## Limits

- No real microphone, speaker, OS permission prompt, echo cancellation,
  network loss mid-utterance or live provider is verified here.  Those
  remain manual hardware checks (see
  [voice-turn-taking.md](../voice-turn-taking.md#deterministic-tests-and-what-they-do-not-cover)).
- The away card's window is a desktop feature of the Flutter client.  On
  the web there is no native window and the persistent in-app card is the
  only surface; there, and on a compositor that refuses the window, the
  card stays over the page rather than vanishing under the pointer.
- Always-on-top is a request.  X11 window managers and macOS honour it;
  Plasma on Wayland is given it through KWin's scripting interface, which
  this app loads itself and unloads with the card; other Wayland
  compositors have no client request for it, so the small window may be
  covered by the window the person raises later.  It is still a separate,
  non-activating window: clicking or dragging it does not hide it.  The
  `HARNESS_BUDDY_WINDOW=off` switch keeps the in-app fallback for a
  machine whose compositor cannot draw the window at all.
- The Linux window's frame comes from a zero-height GTK titlebar and its
  height from the card's measured size.  Both are GTK 3 details of this
  embedder, reached through FFI because Flutter's windowing API has no
  policy for either: a future Flutter/Gtk embedder could make them
  unnecessary, and the window then falls back to the API's own frame and
  size.  The KWin script is Plasma-specific; there is no equivalent for
  GNOME, Sway or a tiling compositor, where the card stays a normal
  window.
- The window uses Flutter's experimental windowing API and `nativeapi`
  for the window properties.  The API is pinned with the SDK
  (`.flutter-version`); a Flutter upgrade may change it.  The window is
  non-focusable by design, so its card is pointer-operated and what has no
  keyboard path is reached through the bar or the call view (see Privacy
  and accessibility).
- A native window cannot be opened in the widget-test engine: the seam is
  tested with a fake and the real window is compiled and smoke-run, not
  exercised for pixels.  The pictures of the card come from the same
  widget the window draws.  `tool/buddy_window_probe.dart` runs the real
  card in the real window; it was observed under a nested Wayland
  compositor (`kwin_wayland --virtual`) as a Plasma session and as a GNOME
  session, and its frame, size and stacking were read back from KWin's
  window model.  The X11 path could not be observed here: Xwayland on this
  machine crashes in its NVIDIA EGL initialisation, so the X11 hints are
  the GTK documentation's, not a screenshot's.
- Window focus is reported by Flutter's app lifecycle.  A desktop
  embedder that reports no `inactive` state would leave the card unshown
  and the bar in place; the call is never affected.
- The buddy is one surface for one selected workspace.  Several
  workspaces at once and call-back when a routine finishes are the
  workspace mode's staged design, not this slice.
- The bar's icon controls carry accessible names and semantics tooltips,
  not hover popups: the bar is above the navigator and has no overlay of
  its own.  The card and the full call view keep their hover tooltips.

## Primary references

Desktop surfaces and the host OS:

- [Flutter desktop support](https://docs.flutter.dev/platform-integration/desktop)
- [Flutter app lifecycle](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html) (`resumed`, `inactive`, `hidden`, `paused`)
- [`AppLifecycleListener`](https://api.flutter.dev/flutter/widgets/AppLifecycleListener-class.html)
- [Flutter `OverlayPortal`](https://api.flutter.dev/flutter/widgets/OverlayPortal-class.html)
- [Flutter windowing API](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/widgets/_window.dart) (`WindowManager`, `RegularWindowController`; experimental in Flutter 3.47)
- [`nativeapi`](https://pub.dev/packages/nativeapi) and [`nativeapi_flutter`](https://pub.dev/packages/nativeapi_flutter) (window properties such as always-on-top, non-activating and focusable)
- [`window_manager`](https://pub.dev/packages/window_manager) (Linux, macOS, Windows; window levels, `alwaysOnTop`, `skipTaskbar`)
- [`desktop_multi_window`](https://pub.dev/packages/desktop_multi_window) (a Flutter engine per window)
- [`tray_manager`](https://github.com/leanflutter/tray_manager) (system tray; the documented GNOME limitation)
- [Microsoft: Notifications and the Notification Area](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area) (the notification area is not for quick command access or critical information)
- [Apple Human Interface Guidelines: Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Freedesktop Window Manager Specification](https://specifications.freedesktop.org/wm-spec/latest/) (window states such as above)

Voice state and privacy:

- [Realtime voice: UI states](../voice-realtime.md#ui-states)
- [Voice turn-taking: live conversation controls](../voice-turn-taking.md#live-conversation-controls)
- [OpenAI Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad)
- [OpenAI GPT-Live prompting: interruptions](https://developers.openai.com/api/docs/guides/live-prompting)
- [Alexa light ring guidance](https://developer.amazon.com/en-US/alexa/branding/alexa-guidelines/brand-guidelines/light-ring)
- [Google Nest speaker lights](https://support.google.com/googlenest/answer/7073219)
- [Android privacy indicators](https://source.android.com/docs/core/permissions/privacy-indicators)
- [Apple: orange and green indicators](https://support.apple.com/en-us/108331)

Accessibility:

- [WCAG 2.2](https://www.w3.org/TR/WCAG22/): 1.4.1 Use of Color, 2.1.1 Keyboard, 2.3.3 Animation from Interactions, 2.4.7 Focus Visible, 4.1.3 Status Messages
- [Flutter accessibility](https://docs.flutter.dev/ui/accessibility)
- [Flutter `MediaQueryData.disableAnimations`](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html)
- [Flutter `Semantics`](https://api.flutter.dev/flutter/widgets/Semantics-class.html)
