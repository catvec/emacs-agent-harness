# The compact voice buddy: one circle, its real state, and what a phone allows

Design note, November 2026.  **This page refines**
[workspace-voice-buddy.md](workspace-voice-buddy.md) and is **not implemented
beyond the in-app circle described below.**  The away card and the in-call bar
already exist and are unchanged in their lifecycle; what changes is how much
they say, and how a call can be present on a phone away from the app.

Three questions this page answers:

1. The voice pipeline now draws its own picture
   ([voice-pipeline-visualization.md](../voice-pipeline-visualization.md)).
   The buddy no longer needs to repeat that picture in words.
2. What is the smallest buddy that still tells the truth — a **circle** whose
   ring and colour follow the last *actually reported* pipeline state, with the
   words and the controls one step away rather than always on screen.
3. Can that circle float over a phone's other apps as Picture-in-Picture?

The answer to 3 is **no, not as a free-floating circle**, on either phone
platform.  The rest of this page records exactly how far each supported path
does go, so nothing is promised that the OS does not do.

## The problem with the current card

The compact card carries every fact the call has: workspace, thread, connection
pill, provider, phase, microphone line, level meter, an activity chip, Start and
End, Mute, Pause, Interrupt, Voice settings, a problem box with Retry, and a
note.  That was right when the card *was* the only compact surface.  It is not
right now:

- the full call view draws the pipeline strip, so the card's status word, level
  meter and activity chip restate it in a worse place;
- a permanently labelled pipeline in a 312 px card is a second, narrower
  implementation of the same facts, which is what the review asked to avoid;
- the card is the *away* surface.  Away means "glance, not read".

Noah's direction: the ordinary buddy should be a small circle — a profile
photo or avatar — whose ring, styling or colour says the most recent real state
of the call, with the small detail available but not standing there.

## One call, one source of state

Nothing in this page adds a second controller, a second capture path or a
second call.  The circle reads:

| Read from | Field | Meaning |
| --- | --- | --- |
| `WorkspaceBuddyController.model` | `status.phase` (`BuddyPhase`) | the status word: `Listening`, `Hearing you`, `Working`, `Speaking`, … |
| `WorkspaceBuddyController.model` | `status.mic` (`BuddyMic`) | what capture is doing: `Mic live`, `Mic muted`, `Mic off`, … |
| `WorkspaceBuddyController.model` | `status.extraOutput` | concurrent output (a reply held while the person speaks) |
| `WorkspaceBuddyController.model` | `connection`, `problem`, `note`, `canEnd`, `canMute` | connection, errors, lifecycle notes, which controls work |
| `VoiceController.pipelineState` | `VoicePipelineSnapshot` | the same tracker the strip and the Emacs line use: `input`, `level`/`levelSeen`/`levelStale`, `speechActive`, `accepted`/`dropped`, turn, `playing`, `problemLabel` |

`buddyPhaseFor`, `buddyMicFor` and `buddyStatusFor` in
`lib/src/voice/voice_buddy.dart` already resolve these with the Emacs
precedence (`harness-voice-live--status`), and the strip's tracker is the one
`VoiceController` owns.  The circle adds no state of its own; it is a pure
function of the model, exactly as `WorkspaceCallBarView` is.

## The circle

A 44 px circle (48 px at 150% text) with two parts:

- **the face** — the workspace's mark, or a person's avatar when the device has
  one.  It is identity, not state, and it never moves;
- **the ring** — 3 px, drawn from the *most recent reported* state, plus a small
  glyph at the ring's lower-right that repeats the ring's meaning without
  colour.

The ring is the only thing that changes.  It is not a meter, not a waveform and
not a progress arc: it is a full ring in a colour and a glyph.  A level, when
the backend reports levels, modulates the ring's *opacity* between 0.55 and
1.0 — that is a measurement, it stops when the reports stop, and it is off
under reduced motion.  **Nothing on the circle runs on a clock**: no sweep, no
breathing, no spinner.  The ring is redrawn when a report arrives, exactly like
the pipeline strip, so a hung backend leaves a still ring rather than a
plausible animation.

### The ring's state table

Every row is a state the controller really reports today.  The colour is never
the only cue: the glyph, the tooltip and the semantics label carry the same
fact.

| Reported state | `BuddyPhase` / `BuddyMic` | Ring | Glyph | Word |
| --- | --- | --- | --- | --- |
| no call | `off` / `off` | neutral outline, no fill | none | `Off` |
| opening the backend | `starting` / `starting` | amber, solid | `more_horiz` | `Starting` |
| capture open, quiet | `listening` / `live` | moss, 3 px | `hearing` | `Listening` |
| capture open, speech heard | `hearing` / `live` | moss, 4 px | `graphic_eq` | `Hearing you` |
| a burst in transcription | `transcribing` / `live` | amber, 3 px | `text_fields` | `Transcribing` |
| the model is working | `working` / `live` | amber, 3 px | `build_circle` | `Working` |
| output held back | `holdingReply` / `live` | amber, 3 px, gap at the top | `pause_circle` | `Holding reply` |
| the player is playing | `speaking` / `live` | moss, 3 px, with the level pulse | `volume_up` | `Speaking` |
| output interrupted | `interrupted` / `live` | slate, 3 px | `stop_circle` | `Interrupted` |
| capture closed by the person | `muted` / `muted` | slate, dashed, 3 px | `mic_off` | `Muted` |
| conversation paused | `paused` / `paused` | slate, dashed, 3 px | `pause_circle` | `Paused` |
| waiting on an approval | `approval` / `live` | amber, 3 px | `front_hand` | `Approval needed` |
| stop in progress | `ending` / `closing` | slate, 3 px | `call_end` | `Ending` |
| stopped | `ended` / `off` | neutral outline | `call_end` | `Ended` |
| the backend reported a failure | `failed` / `off` | error red, 3 px | `error_outline` | `Failed` |
| nothing can be named | `unknown` / any | outline, `?` | `help_outline` | `Status unknown` |

Concurrent input and output stay two facts: when `extraOutput` is not idle the
glyph becomes that output's glyph and the ring keeps the phase's colour, and
the semantics label reads both (`Status · Hearing you` plus `Reply held`).

Honesty rules, enforced in code and in tests:

- **No stage is invented.**  The ring shows a pipeline stage only when
  `VoicePipelineSnapshot` reports it: `speechActive`, a segment in
  `transcribing`, `playing`, `levelSeen`.  A state the backend never reports
  (a "transcoding" or "uploading" stage) has no row and no glyph.
- **A stale level is not activity.**  `levelStale(now)` at 2 s turns the pulse
  off and the tooltip says `Microphone · no level`.  Silence is drawn as
  silence.
- **A colour is not proof of recording.**  `Mic live` comes only from
  `buddyMicFor`; a muted, paused, failed or ended call never draws the live
  ring, and the text line beside the circle says the microphone's state in
  words.
- **The OS indicator is the OS's.**  The circle never imitates, covers or
  claims the platform microphone indicator (the Android privacy dot/chip, the
  iOS orange dot/square).  Where the OS draws one, the circle's job is to agree
  with it, not to replace it.

### Where the circle is drawn

| Surface | Circle | Detail |
| --- | --- | --- |
| in-call bar (every width, every route) | left, replacing today's static `_CallMark` | bar keeps workspace, thread, status word, microphone line, `Mute`, `End`, `Retry`, `Call view` |
| away card (desktop, window not in use) | top-left, 44 px | card is cut down to circle + status word + microphone word + `Mute`/`End` + `Details` |
| call view | unchanged | the full `VoiceScreen` with the pipeline strip |
| Emacs | unchanged | `harness-voice-pipeline-compact-line` stays the compact line |

The away card's cut is the substantive UI change: it keeps the two things a
person away from the app must be able to do — **mute** and **end** — plus the
words that say whether the microphone is open.  Everything else moves behind
`Details`, which opens the existing call view (the same route as `Call view`);
`Voice settings`, `Pause`, `Interrupt` and `Retry` stay in that view.  `Retry`
stays on the card when there is a problem, because a failed call has no other
reachable surface while the window is away.

Sizes: the card keeps its 312 px width so the desktop window's framing,
dragging and content-size reporting (`buddy-window-host.dart`,
`buddy_window_linux.dart`) do not change; it simply gets shorter.  The circle
scales with text to 2× and stops there; the card's width also grows with text,
as it does now.

### Accessibility

- The circle is a `Semantics` node labelled `Voice buddy` with the status and
  microphone words: `Status · Listening · Mic live`.  It is not a button on its
  own; the controls beside it are.
- Colour is always paired with the glyph and the words above.  A
  `Differentiate Without Color` / high-contrast setting changes the ring to the
  outlined variants, and the glyph stays.
- Reduced motion (`MediaQuery.disableAnimations`) removes the starting sweep,
  the ending contraction and the level pulse; the ring's colour and glyph
  remain.
- The circle itself does not animate to a new state faster than 160 ms, and
  never more than once per report.
- The bar and the card keep each status and microphone line as its own live
  region, so a screen reader hears a change once, not twice.

### Controls that must not move into the circle

`End` and `Mute` stay 36–44 px targets with names and tooltips in the bar and
on the card at every state in the table — including `Failed`, `Unknown`,
`Muted`, `Paused` and `Ending`.  The circle never becomes the only way to end
a call, and it is never the target a person must hit to stop recording.

## The phone question: what Android and iOS actually allow

Noah's idea is a small circle that stays while the app is in the background,
like a video call's floating window.  Neither phone platform offers an
arbitrary always-on-top circular window.  These are the real surfaces, what
each one is for, and what it can carry.

### Android

| Surface | Supported? | What it can show | What it cannot do |
| --- | --- | --- | --- |
| **Picture-in-Picture** (`enterPictureInPictureMode`, API 26+) | yes, for an **Activity** the app declares `android:supportsPictureInPicture="true"` | the activity's own UI, scaled into a system-placed window; aspect ratio constrained to **2.39:1 … 1:2.39**; custom `RemoteAction`s in the window's menu (single tap, Android 12+), an optional expanded PiP (Android 13+, `FEATURE_EXPANDED_PICTURE_IN_PICTURE`) | it is **the app's activity**, not a detached circle: whatever the activity draws is what the window shows, including the workspace page behind it; **the app does not get input focus** in PiP (`MediaSession.setCallback()` is the documented way to receive input events), and the docs steer PiP to video, video calls and navigation — "avoid showing anything except video content"; it may be unavailable on low-RAM devices (`FEATURE_PICTURE_IN_PICTURE`) |
| **System alert window / overlay** (`SYSTEM_ALERT_WINDOW`, `TYPE_APPLICATION_OVERLAY`) | a permission the person grants in Settings | a view drawn over other apps, any shape | it is a **special permission** the Play policy restricts to specific purposes; the PiP page says explicitly **not** to use a system alert window for a PiP experience; and the project's rules forbid a new broad OS permission without action-time approval |
| **Notification** (with `MediaStyle` or custom actions) | yes | a small icon, title, text, up to three actions, a live chronometer; the ongoing-call shape | it is a notification, not a floating window; it cannot be circular, and its content is text and icons only |
| **Ongoing-call chip / status bar** | system-owned | the OS's own chip | not the app's to draw |
| **Foreground service (microphone)** | yes, `foregroundServiceType="microphone"` + `FOREGROUND_SERVICE_MICROPHONE` + granted `RECORD_AUDIO` | keeps capture alive while the app is not visible | **Android 14+ cannot create a microphone foreground service from the background** (`SecurityException`); it must be started while an activity is visible, unless one of the documented exemptions applies (a notification action, a widget, a `PendingIntent` from a visible app, …) |

So on Android the legitimate path to "the call stays alive and visible while
I use another app" is: **a microphone foreground service, started from the
visible app, plus a PiP window and/or an ongoing notification.**  The PiP
window would show the app's own minimized call surface — so the honest design
is a *compact* PiP layout (circle + `Mute` + `End`), not a circle floating on
its own.  That is a real feature, and it is **not implemented here**: it needs
`supportsPictureInPicture`, `configChanges`, a foreground service and a
permission, none of which this refinement may add.

The OS privacy indicator is independent: Android shows a microphone dot/chip
for as long as an app's microphone access is active (active = running or less
than five seconds old, Android 12+), whether or not the app draws anything.
The circle must not try to look like it.

### iOS

| Surface | Supported? | What it can show | What it cannot do |
| --- | --- | --- | --- |
| **Picture in Picture** (`AVPictureInPictureController`) | yes, for **video** from an `AVPlayerLayer` / `AVSampleBufferDisplayLayer`, or a call UI via `AVPictureInPictureVideoCallViewController` (iOS 15+) | the system's PiP window with playback controls | Apple's guidance: **only begin PiP in response to user interaction, never programmatically** (App Store review rejects otherwise); visual content must be the player's; `isPictureInPicturePossible` can be false (e.g. while FaceTime is active); it is video-shaped, not an arbitrary widget |
| **Background audio** (`UIBackgroundModes` → `audio`, `AVAudioSession` `.playback`) | yes, with the capability in the target | audio keeps playing when the app is backgrounded or the device is locked | audio only; there is **no** floating visual surface for it.  This app's `Info.plist` has **no `UIBackgroundModes`**, so today neither the player nor capture survives backgrounding |
| **Live Activity** (ActivityKit, iOS 16.1+) | yes, with a WidgetKit extension | a glanceable, SwiftUI-drawn card on the Lock Screen and in the Dynamic Island, updated from the app with ActivityKit, with buttons/toggles | it is a Lock Screen / Dynamic Island presentation, not a window over other apps; it needs a **widget extension target**; it cannot be started while the app is not in the foreground without a push; frequent updates are budgeted by the system |
| **Notification** (with actions) | yes | text, icons, actions | not a floating window |
| **Camera/microphone in PiP** | iOS 16+ can keep a **camera** capture session running in PiP (`isMultitaskingCameraAccessEnabled`); earlier needs an entitlement | — | this is about a camera capture session, not an audio-only avatar |
| **Arbitrary overlay window** | **not available to third-party apps** | — | no `SYSTEM_ALERT_WINDOW` equivalent |

So on iOS there is **no supported path to a floating audio-only circle.**  The
two honest options are a **Live Activity** (a card in the Dynamic Island / Lock
Screen, which *is* the closest thing to "a small thing always there") and
**background audio** (the call keeps running with the OS's orange indicator,
and the app's own bar is there when the person returns).  Both require changes
this refinement does not make: a widget extension target, and the
`UIBackgroundModes` capability.

The orange indicator is the OS's confirmation of capture (a square when
Differentiate Without Color is on).  It is not something the app can draw,
suppress or imitate, and the circle must not be read as one.

### What this means for the concept

| The idea | Verdict |
| --- | --- |
| a small circle floating over other apps on a phone | **not supported** on either platform through legitimate APIs |
| a minimized call view in Android PiP, shaped as a compact circle + `Mute` + `End` | **supported** (activity-scoped, with a foreground service if capture must continue); not implemented |
| an Android ongoing notification with `Mute` / `End` | **supported**; not implemented |
| an iOS Live Activity with the same state | **supported** (iOS 16.1+, widget extension); not implemented |
| an iOS floating circle | **not supported** |
| a call that keeps running while backgrounded | Android: foreground service, started while visible.  iOS: `audio` background mode.  Neither exists in the app today |

### The honest fallback, in the order this design recommends it

1. **Today, unchanged:** the in-call bar is the call's presence at every width
   and every route, and the circle is its left mark.  Backgrounding the app
   keeps the call's state; the OS indicator shows the microphone; the bar with
   `Mute` and `End` is back the moment the app is foregrounded.  This is what
   already works.
2. **Android, next:** a compact PiP layout for the call view
   (`supportsPictureInPicture`, `configChanges`, an aspect ratio near 1:1, a
   `RemoteAction` for `End`, and the foreground service when capture must
   survive).  This is what Noah described, and it is reachable, but it is a
   separate task with its own manifest, service and permission work.
3. **iOS, next:** a Live Activity showing the same circle-and-words state, plus
   `audio` background mode if the call should survive backgrounding.  Requires
   a widget extension target and an App Store-shaped review of the update
   budget.
4. **Never:** an overlay window on iOS, a `SYSTEM_ALERT_WINDOW` circle on
   Android, or any surface that claims to be the microphone indicator.

## What changes in this task

Deliberately small, and reversible:

| Area | Change |
| --- | --- |
| `lib/src/voice/voice_buddy.dart` | `BuddyRing` (colour, glyph, word, thickness) resolved from `BuddyStatus`, plus `buddyRingFor`; tests can state one directly |
| `lib/src/ui/widgets/voice_buddy_dot.dart` | the circle widget: face, ring, glyph, level pulse, reduced motion, semantics |
| `lib/src/ui/widgets/workspace_call_bar.dart` | the left mark becomes the circle; the status and microphone words stay exactly as they are |
| `lib/src/ui/widgets/workspace_buddy.dart` | the card is cut down: circle, workspace, status word, microphone word, `Mute`/`End`, `Details`, and the problem box with `Retry` when there is one |
| `test/voice_buddy_dot_test.dart` | the state table, exact copy, non-colour cues, reduced motion, stale level, semantics |
| `test/workspace_buddy_widget_test.dart`, `test/workspace_call_bar_test.dart` | the cut-down card and the bar's circle, exact copy |
| `docs/design/workspace-voice-buddy.md` | a pointer to this page and the shortened card's copy inventory |

Not changed: the controller, the call lifecycle, the native window code, the
call view, Emacs, any permission, any platform configuration, the public
surface of `WorkspaceBuddyController`.

## Copy inventory

Noun phrases and adjectives only; provider and error text stay data.

| Place | Copy |
| --- | --- |
| Circle semantics | `Voice buddy` + `Status · <word>` + `<mic word>` |
| Circle tooltip | `Voice buddy · <word>` |
| Status words | the `BuddyPhase` labels already in use: `Off`, `Starting`, `Listening`, `Hearing you`, `Transcribing`, `Working`, `Holding reply`, `Speaking`, `Interrupted`, `Muted`, `Paused`, `Approval needed`, `Ending`, `Ended`, `Failed`, `Status unknown` |
| Microphone words | `Mic off`, `Mic starting`, `Mic live`, `Mic muted`, `Mic paused`, `Mic closing` |
| Concurrent output | `Speaking`, `Reply held`, `Working` |
| Card heading | `Buddy` |
| Card details control | `Details` (tooltip `Call · view`) |
| Card controls | `Mute` / `Unmute`, `End`, `Retry`, `Buddy · off` |
| Level tooltip | `Microphone · level` / `Microphone · no level` |
| Connection pill | `Connected` / `Reconnecting` / `Offline` (unchanged) |

Removed from the card (still in the call view): `Pause`/`Resume`, `Interrupt`,
`Voice settings`, the provider chip, the level meter's own row, the separate
activity chip.  The level becomes the ring's pulse and its tooltip.

## Verification

- Widget tests for every row of the ring table, including `unknown`, a stale
  level, muted, failed and ended; exact strings for the circle, the card and
  the bar; a semantics test that the status and microphone words are announced;
  a reduced-motion test that the pulse and sweep are absent while the words
  stay.
- Screenshots of the circle in `Listening`, `Hearing you`, `Speaking`,
  `Muted` and `Failed`, plus the cut-down card and the phone bar: see
  [the evidence](../evidence/voice-buddy-compact/README.md).
- `flutter analyze`, the focused widget tests, then `check_build.sh`, the full
  `scripts/test.sh` and `scripts/lint.sh` on the committed tree.
- **Not verified here, and stated as such:** anything on a real Android or iOS
  device.  The platform claims above are read from the vendor documentation
  cited below; no PiP window, foreground service, Live Activity or background
  audio was built or run, because each needs a permission, a manifest or a
  target change this task does not authorize.

## Sources

Android

- [Use picture-in-picture](https://developer.android.com/develop/ui/views/picture-in-picture) — API 26+, `supportsPictureInPicture`, `configChanges`, system-placed window, single-tap controls and `setActions`, "no input focus in PiP", "avoid showing anything except video content", `FEATURE_PICTURE_IN_PICTURE`, "don't use a system alert window" for PiP.  Last updated 2026-10-28.
- [`PictureInPictureParams.Builder`](https://developer.android.com/reference/android/app/PictureInPictureParams.Builder) — `setAspectRatio` constrained to 2.39:1 … 1:2.39 (API 26), `setActions`/`getMaxNumPictureInPictureActions` (≥ 3), `setExpandedAspectRatio` + `FEATURE_EXPANDED_PICTURE_IN_PICTURE` (API 33), `setSeamlessResizeEnabled` (API 31), `setCloseAction` (API 33).
- [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types) — `microphone` type, `FOREGROUND_SERVICE_MICROPHONE`, `RECORD_AUDIO`, "you cannot create a microphone foreground service while your app is in the background".
- [Restrictions on starting foreground services that need while-in-use permissions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start) — Android 14+ throws `SecurityException`; start while a visible activity; the documented exemptions (notifications, widgets, `PendingIntent` from a visible app).
- [Privacy indicators](https://source.android.com/docs/core/permissions/privacy-indicators) — microphone/camera indicators, active = running or < 5 s old (Android 12+), tap to see the app.

iOS

- [Adopting Picture in Picture in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player) — `AVPictureInPictureController`, `AVPlayerLayer`/`AVSampleBufferDisplayLayer`, "begin PiP playback only in response to user interaction and never programmatically", `isPictureInPicturePossible`.
- [`AVPictureInPictureVideoCallViewController`](https://developer.apple.com/documentation/avkit/avpictureinpicturevideocallviewcontroller) — iOS 15+, video-call content in PiP; iOS 16+ camera in PiP via `isMultitaskingCameraAccessEnabled`.
- [Configuring your app for media playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback) — `AVAudioSession` `.playback`, Background Modes "Audio, AirPlay, and Picture in Picture" (`UIBackgroundModes`), needed for background audio **and** for PiP.
- [ActivityKit](https://developer.apple.com/documentation/activitykit) — Live Activities, iOS/iPadOS 16.1+, Dynamic Island and Lock Screen, SwiftUI/WidgetKit, updates from the app or by push.
- [About the orange and green indicators in your iPhone status bar](https://support.apple.com/en-us/108331) — orange dot = microphone (square with Differentiate Without Color), green = camera (or camera + microphone).

Repository

- [workspace-voice-buddy.md](workspace-voice-buddy.md) — the call view, the in-call bar, the away card and their copy inventory.
- [buddy-window-fixes.md](buddy-window-fixes.md) — the native away window's frame, size, stacking and existence rules.
- [voice-pipeline-visualization.md](../voice-pipeline-visualization.md) — the strip the circle reads from, and its "nothing moves on a clock" rule.
- [voice-realtime.md](../voice-realtime.md) — the UI states and the precedence both clients follow.
