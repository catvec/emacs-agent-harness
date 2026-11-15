# Real mobile computer capture and control

A phone that registers as a harness computer should offer what its OS
actually lets it offer -- its camera, its screen, its microphone, its
files -- and, where the platform has a legitimate way to do it, a
pointer and a keyboard.  This document says what was built, what the
alternatives were, and what is deliberately not claimed.

Companion: [The mobile client as a computer](mobile-computer.md) is the
app-side reference; [Computers](computers.md) is the harness contract.

## The shape of the problem

Before this change the app could register as a computer and lend its
scoped files, but every capture capability read `Unavailable` from a
no-op port, the identity and the files lived in a cache directory the OS
may reclaim, the secret was plain in a JSON file, and the page said the
app offered no pointer or keyboard at all.  The harness's `camera`,
`view` and `audio` tools therefore answered with an error, and an agent
had no way to touch the phone.

Four things had to be true at once:

1. A capability is advertised only when the OS says it is usable, and
   each is gated independently -- a person may want files and not a
   camera.
2. Capture stops when the person withdraws it, the app leaves the
   foreground, or the connection goes, and it never resumes by itself.
3. A late frame from before a stop is refused, not counted.
4. There is one camera and screen stack in the app, not two.

## Decisions

### One capture stack, borrowed through a narrow seam

The live-video task (`t-ippnm26k`) owns `MediaCaptureSession` and its
platform ports.  Rather than build a second camera/screen implementation
for computer use, this branch defines `ComputerMediaCapture` -- `present`,
`start`, `stop`, `frame`, `clip`, `signals`, `handleLifecycle`, `dispose`
-- and a `SessionComputerCapturePort` that implements the harness's
`ComputerCapturePort` on top of it.

The alternative was to let the computer endpoint drive the media session
directly.  That would have put the harness's capability vocabulary, the
generation counter and the lifecycle rules into the media code, which the
voice and screen-share features also use; every one of them would then
have had to agree about when a frame is stale.

The split is: the port owns what the *harness contract* needs (which OS
permission gates which source, what a capability state is, the generation
that refuses a late frame, the stop on revocation or lifecycle change);
the media session owns what a *camera and a screen* need (consent flow,
foreground service, encoder).

While the peer branch is unmerged, the app injects
`NoopComputerMediaCapture`, whose `present` is false.  Screen, camera and
microphone then read `Capture session not connected` and are not
advertised.  That is the honest state of this branch and it is stated in
the hand-in rather than papered over.

### Permissions are read as a value, never awaited on the connection path

The first attempt read the OS through a `MethodChannel` inside
`ready()` and `refreshCapabilities()`.  `AppController.connect()` awaits
`MobileComputerController.ready()`, so every connecting test hung: a
`flutter_test` `MethodChannel` is never answered, and a pending `Timer` to
bound it trips the `'!timersPending'` invariant.  Sixty-four tests that
have nothing to do with computers failed.

The fix is a value object, `PlatformFacts` (permissions, storage root,
control state, whether the platform can seal a secret, and whether the OS
was asked at all).  It is read once at start in the background, held by
the controller, and read again only when the person asks
(`refreshPlatform`) or the app resumes.  The endpoint is handed
`() => facts.control` -- a synchronous read of that held value -- so a
capability refresh never waits on a channel.

The alternative, a `Timer`-bounded channel call, was tried and removed:
it leaves a pending timer in widget tests even when it is cancelled, and
"give up after N milliseconds" invents a permission state from silence.

### A permission the OS has not answered says so

`PlatformFacts.read` distinguishes "the OS said nothing" from "the OS
said no".  A test, the web and a desktop build leave it false, and the
page reads `Not checked` rather than inventing `Denied`.  `Permission not
checked` is also what a capture start refuses with, so an agent gets a
reason instead of a hang.

### The system control is a separate, visible grant

Viewing a screen is not control, so the app never treats one as the
other.  On Android it declares an `AccessibilityService` with
`exported="false"` that performs a tap, a scroll, a drag and text
insertion.  No app may enable an accessibility service for itself: the
person turns it on in the OS settings, and the app only *reads* whether
it is on.  The endpoint advertises `pointer` and `keyboard` only while the
person's switch is on **and** the OS reports the service enabled, and a
gesture that crosses a stop, a revocation or a lifecycle change is
refused like a late frame.

The alternative -- an app-scoped input channel that drives only the app's
own widgets -- was rejected as not being computer use: an agent that can
only type into the harness app has not been given the phone.

iOS gets no control at all.  There is no public system-wide touch or
keyboard injection, and the page says `Pointer and keyboard · app-scoped
only` rather than promising a capability the platform cannot give.  No
jailbreak, no root, no private API.

### Durable private storage and a sealed secret

The identity and the scoped files move from `Directory.systemTemp` to the
platform's app documents directory (`filesDir` on Android, `Documents` on
iOS).  The 256-bit secret is sealed in the platform keystore -- Android
Keystore `AES/GCM` with a non-exportable key, or the iOS Keychain -- and
is not written to the identity file at all when that works.  A build with
no channel falls back to the temporary directory and the file, and the
page says `Storage · Temporary directory`.

The alternative, `flutter_secure_storage`, adds a dependency and a plugin
for what is a hundred lines of platform code, and hides which protection
the secret actually has.  The channel reports it, so the page can tell the
truth.

### Copy

New labels are noun phrases, per the repository's UI rule: `Pointer`,
`Keyboard`, `System control off · OS settings`, `Settings`, `Storage · App
documents`, `Storage · Temporary directory`, `Storage · Not checked`,
`Pointer and keyboard · no system control`, `Pointer and keyboard ·
app-scoped only`, `Capture session not connected`, `Permission not
checked`, `Off on this phone`, `No system control on this platform`.

## What the harness sees

The `computer` MCP server gains `pointer` and `keyboard` beside `info`,
`screenshot`, `camera`, `audio` and `clipboard`; each is listed only while
its capability is offered.  The harness's `computer_pointer` and
`computer_keyboard` reach them through the same authenticated
`_harness/computer/mcp` path, and its own gate still decides whether a
session may use them.

Capability states are the harness's own: `available`, `denied`,
`revoked`, `unavailable`, `foreground-only`, `suspended`, `error`.  Only
`available` and `foreground-only` are advertised as offered.

## Verification

- `flutter analyze` -- no issues.
- `flutter test` -- the same result as `main` measured on the same
  machine (the 21 pre-existing failures in unrelated suites are identical
  before and after this branch; there are no new ones).
- `test/computer_endpoint_test.dart` -- identity and secret, scoped
  files, MCP methods, registration, handshake-before-token, stale token,
  a screen capture, a late frame after a stop, a revoked permission,
  lifecycle pause that never resumes, the system control gated by the
  OS, a control call refused while it is off, a platform with no input
  injection, and a performed gesture plus its refusal reason.
- `test/computers_test.dart` and `test/computers_screenshots_test.dart`
  -- the page's exact rendered copy and its picture.

Not verified, and stated as a blocker: the native Android and iOS paths
at runtime.  There is no Android SDK, emulator or iOS toolchain in this
environment, so the channel, the keystore and the accessibility service
are compiled code that has not been run on a device.  The capture
capabilities are additionally blocked on `t-ippnm26k` landing its
`MediaCaptureSession`.
