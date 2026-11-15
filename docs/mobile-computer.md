# The mobile client as a computer

A client and a computer are separate things: a client reads and enacts
the harness's state over ACP, and a computer is a machine whose tools the
harness may call.  The Flutter client (`harness_client/`) is both.  It
draws the Computers page and the RFB view, and it can register the phone
or desktop it runs on, lend that computer's tools as MCP servers over its
ACP connection, and keep no harness state of its own.  The server stays
the engine: it keeps the registry, the access policy, the event loop and
the session transcripts.

This document is the app's side of [computers](computers.md).  The harness
contract -- records, grants, the gate, the ACP methods and the MCP host --
is there and in [architecture](architecture.md#computers).

## Shape

```
Flutter app (one process)                    harness server
┌─────────────────────────────┐              ┌──────────────────────────┐
│ MobileComputerController    │  ACP (WS)    │ harness-acp              │
│  identity + secret          │◄────────────►│  client session          │
│  capability opt-ins         │              │ harness-computers        │
│  capture port               │              │  record, grants, gate    │
│ MobileComputerEndpoint      │              │ harness-mcp              │
│  computer MCP server        │◄────────────►│  external connection     │
│  files MCP server           │ _harness/    │  initialize, tools/list, │
│  token check, file scope    │ computer/mcp │  tools/call              │
└─────────────────────────────┘              └──────────────────────────┘
```

Nothing but the ACP connection crosses the boundary.  There is no second
port, no listener in the app and no harness record in the app: an
in-process MCP server is reached exactly like the Emacs endpoint's, by
the harness sending `_harness/computer/mcp` to the client that registered
it.  When the client leaves, its registration is marked disconnected and
its tools go with it.

## Identity and registration

- The identity is `cmp-<os>-<random>`, stable for the installation.  The
  secret is 256 random bits, base64url without padding.  Both are kept in
  `harness-computer/identity.json` in the app's own file area.  On a
  phone that is the app's documents directory (`filesDir` on Android,
  `Documents` on iOS), which the OS does not reclaim, so the id survives a
  reboot and a cache trim.  The secret is sealed in the platform's own
  keystore -- the Android Keystore (`AES/GCM`, a non-exportable key) or
  the iOS Keychain -- and is not written to the file at all when that
  works.  A build with neither falls back to the file, and
  `Storage · Temporary directory` says so on the page.  The wire format is
  the same either way.
  `ComputerIdentity.load` also downcases an id it finds, because the
  harness keeps computer ids lowercase and a client that kept another
  case could not find its own record.
- The id is generated lowercase for the same reason.  The secret is never
  hashed on the device; the harness keeps only a salted SHA-256 of it.
- Registration is explicit.  The Computers page's `[Register]`
  button calls `computer/register` with the computer description, the
  secret, the resources (the app-files directory, and a display, camera
  and microphone while those capabilities are offered) and the two MCP
  servers.  Nothing registers on the app's behalf at connect time; a
  registered installation reconnects with `computer/attach` and its
  secret.
- The harness attaches the MCP servers *before* it answers `register` or
  `attach`, because the answer carries the MCP token.  The handshake
  (`initialize`, then `notifications/initialized`) therefore arrives
  while the app still waits for the token.  `MobileComputerEndpoint`
  accepts that handshake only while a bind (`register` or
  `attachIfKnown`) is in flight; once it settles, every MCP message must
  carry the token of the current registration, compared in constant
  time.  Both directions prove the binding: the harness sends only on the
  connection of the client it bound to the computer, and the client sends
  only for its own id, its own server names and its current token.

## Capabilities

The vocabulary is the harness's: `view`, `camera`, `audio`, `files`,
`clipboard`, and -- where the platform has it at all -- `pointer` and
`keyboard`.  Each is a person's opt-in on the page, and separate from
the harness's grant: the harness may allow a session a capability the app
does not offer, and an app may offer one the session is not granted.
Only a capability the person turned on and the platform reports usable is
advertised in `computer/register` and `computer/update`.

A capability is in one of the harness's states: `available`, `denied`
(the OS refused), `revoked` (the person or the OS withdrew it),
`unavailable`, `foreground-only`, `suspended` (the app left the
foreground), or `error`.  Only `available` and `foreground-only` count as
offered.  Capabilities travel both as the offered list and as
`capabilityStates`, so the Computers page and `session_info` can say why
one is not there.

`MobileComputerController` is a `WidgetsBindingObserver`.  When the app
goes to the background, every capture stops, the capability state says
`suspended` and the change is advertised; nothing resumes by itself when
the app comes back.  `[Capture off]` bumps a generation, stops the
capture and advertises the change; a frame or clip that finishes after
the bump is refused rather than counted.

Screen, camera and microphone are behind `ComputerCapturePort`.  The port
owns the OS permission checks, the capture session, the lifecycle and the
frame format; the endpoint owns the MCP tool, the state machine and the
token.  This build's port is `SessionComputerCapturePort`, which drives
the shared `MediaCaptureSession` of the live-video work rather than a
second camera or screen stack of its own (see [Shared capture](#shared-capture)).
Clipboard is implemented by the controller through Flutter's `Clipboard`,
in the foreground only.  Files is implemented by the app's scoped store.

## The tool servers

The `computer` server:

| tool | does | offered while |
| --- | --- | --- |
| `info` | what the phone is, its id, OS, capabilities and servers | always |
| `screenshot` | one PNG of the screen | `view` is offered |
| `camera` | one JPG/PNG picture, with optional width and height | `camera` is offered |
| `audio` | one WAV clip, 1-15 seconds | `audio` is offered |
| `clipboard` | read or write the clipboard | `clipboard` is on |

The `files` server:

| tool | does |
| --- | --- |
| `info` | the root and whether writing is on |
| `list_dir` | one directory, with name, path, type, size and time |
| `read_file` | a text file by line range |
| `file_info` | metadata for one path |
| `write_file` | a text file under `outbox/`, only with writing on |

Every tool answer is an MCP result: text for people, structured content
where the harness's `computer_call` can use it, and `isError` for a
refusal.  The harness's `computer_camera` and `computer_view` tools call
the matching server tools and turn the structured image into a session
picture, so the transcript shows the picture the phone took.  A tool the
app does not offer is refused before the MCP call, with the capability's
state in the reason.

## Files

`AppComputerFileStore` roots the app's files at
`harness-computer/` in the app's file area, with `imports/` and
`outbox/`.  Only relative paths are accepted.  Absolute paths, `..`, NUL
bytes and symbolic links are refused, and the resolved path must stay
under the root.  A person's import is a copy the system picker chose,
never the original path; the agent sees the copies.  Writes need the
person's switch and go to `outbox/` only.  The limits are 512 KiB for a
read or import and 256 KiB for a write, with at most 500 entries in one
listing; over them, the tool answers with an error rather than truncating
silently.  The page shows `[File writing]` (`Outbox only`) and
`[Import file]`.

The root is a cache directory in this build, and the OS may reclaim it;
the import/outbox scope, not durability, is what the store guarantees
today.  Moving it to app documents (or the platform's private files
directory) is a platform-channel change that does not alter the tools.

## The page

The Flutter Computers page gets a `This client` section after
`Resources`: the device's label (`This phone` or `This device`), its name,
id and OS, a registration state (`Not registered`, `Registered`,
`Disconnected`), a switch per capability with its state, `[File writing]`
and `Outbox only` when files are on, `[Capture off]` while a capture is
active, and the buttons `[Register]`, `[Reconnect]`, `[Disconnect]`,
`[Revoke]` and `[Import file]`.  A button that acts says so in the
imperative; the rest is nouns, noun phrases and adjectives like the page
(`System control off · OS settings`, `Storage · App documents`,
`Pointer and keyboard · app-scoped only`, `Screen capture ·
broadcast extension required`).  The page is drawn at the end so the
registry and the resources keep the top of the page.

![The This client card on a phone: its label, the registration state, a switch and state per capability, the pointer and keyboard rows, the system-control note with its Settings button, the storage line, and the registration and file-import buttons](media/computers-phone-client.png)

## Platform matrix

| capability | Android path | iOS path | this build |
| --- | --- | --- | --- |
| screen | `MediaProjection` consent, a foreground service of type `mediaProjection`; from Android 14 a per-session token | a ReplayKit broadcast upload extension | permission read from the OS; capture through the shared media session |
| camera | CameraX, `CAMERA` permission | AVFoundation, `NSCameraUsageDescription` | permission read from the OS; capture through the shared media session |
| microphone | `RECORD_AUDIO` permission | AVAudioSession, `NSMicrophoneUsageDescription` | permission read from the OS; capture through the shared media session |
| files | app documents (`filesDir`) | app documents (`Documents`) | real, scoped, durable |
| clipboard | `ClipboardManager` | `UIPasteboard` | real, foreground |
| pointer | an opt-in `AccessibilityService`, enabled by the person in the OS settings | none: no public system-wide input injection | declared and gated; off until the person turns it on |
| keyboard | the same service's text insertion | app-scoped only | declared and gated; off until the person turns it on |

The Android screen contract is the one on
<https://developer.android.com/media/grow/media-projection>; the iOS
screen contract is ReplayKit's broadcast upload extension,
<https://developer.apple.com/documentation/replaykit>.  The Android
control contract is the accessibility service
(<https://developer.android.com/guide/topics/ui/accessibility/service>),
which no app may grant itself: the person enables it in the OS settings,
and the app only reads whether it is on.

The app does not claim a capability the OS has not reported.  A
permission the OS has not answered reads `Not checked`, a permission it
refused reads `Denied` or `Revoked`, and a capture the app stopped reads
`Suspended` or `Foreground only`; none of them is advertised to the
harness as offered.  The matrix says what the port uses, not that every
build has it: `NoopComputerMediaCapture` is the port's value until the
shared media session is available to this branch (see [Shared
capture](#shared-capture)).

## Decisions and alternatives

- **In-process MCP servers, not helper programs.** The app already has an
  ACP connection, a token and an event loop.  Starting a second process
  to speak MCP would duplicate authentication, add a lifetime to manage,
  and still need the ACP request to reach it.  The harness's MCP host is
  the same host on both ends, and the app's two servers are ordinary
  `McpServer` objects in the app isolate.
- **The registration is the person's, not the connection's.** A connect
  does not register a machine: that would give the harness access as a
  side effect of opening a chat, and would make every reconnect a new
  grant.  The app sends `computer/register` only from the button, and
  `computer/attach` only with a secret it already kept.
- **The capture port is a seam, not a plugin in this change.** Screen and
  microphone capture need an OS consent flow, a foreground service on
  Android and a broadcast extension on iOS; those are platform work with
  their own lifecycle and stores.  Keeping them behind a port lets the
  registration, MCP, token, file and capability machinery be tested
  without a device, and lets the capture work land without changing the
  harness contract.  The port is the same `ComputerCapturePort` the
  Emacs endpoint implements, so the two clients speak one vocabulary.
- **A second permission check is not a second policy.** The harness's
  gate decides what a session may do on a computer; the app's switches
  decide what this phone offers at all.  Both are needed: the person may
  want to advertise files but not camera, and a session may be allowed a
  camera on another computer but not this one.  The page shows the app's
  side and the server's `computer/access` shows the session's.

## What is implemented, and what is not
## Shared capture

There is one capture stack, not two.  The live-video work owns
`MediaCaptureSession` and its platform ports (camera, screen, encoder);
this branch owns the adapter that lends that session to a registered
computer:

```
MobileComputerEndpoint
  └─ ComputerCapturePort            (the harness's vocabulary)
       └─ SessionComputerCapturePort  (this branch: permission, generation, lifecycle)
            └─ ComputerMediaCapture    (the seam: present, start, stop, frame, clip, signals)
                 └─ MediaCaptureSession (t-ippnm26k: the one camera/screen stack)
```

`ComputerMediaCapture` is a narrow interface -- `present`, `start`,
`stop`, `frame`, `clip`, `signals`, `handleLifecycle`, `dispose` -- and
the only production implementer is the peer's `MediaCaptureSession`.
`NoopComputerMediaCapture` implements it as absent, which is what this
branch injects while that session is not on it: the adapter is complete
and tested, the hardware path is not claimed.

The split of responsibility is deliberate.  The port owns what the
harness's contract needs -- which OS permission gates which source,
what a capability state is, the generation that refuses a late frame,
the stop on a revocation or a lifecycle change.  The media session
owns what a camera and a screen need -- the consent flow, the
foreground service, the encoder.  Neither re-implements the other, so
there is no second camera or screen-share stack to keep in step.


- **Pointer and keyboard as a separate- **The shared capture session's own platform work.** This branch owns
  the adapter, not the camera or screen implementation: it consumes
  `MediaCaptureSession` through `ComputerMediaCapture` and injects
  `NoopComputerMediaCapture` while that session is not on this branch.
  Until it lands, screen, camera and microphone read `Capture session
  not connected` and the harness gets no such capability -- stated
  here rather than faked.  See [Shared capture](#shared-capture).
- **A real-device or emulator run.** The Android host code (the channel,
  the keystore, the accessibility service) and the iOS runner are in
  the tree, but this change was checked with `flutter analyze`, the
  Dart suites and the screenshots -- not on a device or an emulator.
  The native paths are therefore unproven at runtime, which is a
  blocker and not a capability.
, visible grant.**  Viewing the
  screen is not control, so the app never treats one as the other.  On
  Android it declares an `AccessibilityService` (`exported="false"`) that
  performs a tap, a scroll, a drag and text insertion; the service is
  off until the person enables it in the OS settings, and the endpoint
  advertises `pointer` and `keyboard` only while that switch is on *and*
  the service reports itself enabled.  A gesture or keystroke that
  crosses a stop, a revocation or a lifecycle change is refused like a
  late frame.  iOS has no public system-wide input injection, so it
  offers no `pointer` or `keyboard` at all and the page says
  `Pointer and keyboard · app-scoped only`; promising otherwise would be
  a capability the platform cannot give.
- **Window control.** Neither platform offers an app a public way to
  move or resize another app's window; there is no such tool.
- **Background capture.** The OS can stop a capture when the app leaves
  the foreground, and the app deliberately does not restart it.  A
  foreground service is the Android path; iOS has no general background
  screen capture.
- **A remote attach flow in the app.**- **Durability of the identity.** The identity, the scoped files and the
  sealed secret are in the app's documents directory and the platform
  keystore.  A build with no channel (the web, a desktop run) still
  falls back to the process's temporary directory, and the page says
  `Storage · Temporary directory` when it does.
 The app attaches to the harness it
  is already connected to.  Registering this phone from another client,
  or attaching it to a second harness, uses the same methods but has no
  page yet.

## Checking it

`harness_client/test/computer_endpoint_test.dart` covers the identity and
its secret, the scoped file store, the four MCP methods, registration,
the handshake that arrives before the token, a stale or wrong token, a
screen capture, a stop during a capture, a revoked permission, lifecycle
pause, revocation, the pointer and keyboard gated by the OS's control
state, a control tool refused while it is off, and a platform with no
input injection never offering it.  `harness_client/test/computers_test.dart` asserts
the page's exact rendered copy and `test/computers_screenshots_test.dart`
takes its pictures, including `computers-phone-client.png`.

`harness_client/test/mobile_computer_e2e_test.dart` is the end-to-end
check and is skipped unless `HARNESS_MOBILE_E2E=1` and
`HARNESS_SERVER_TOKEN` (at least 16 characters) are set.  The script
does both, with the pinned Flutter SDK and the toolchain's pub cache:

```
scripts/mobile-computer-e2e.sh
```

or by hand:

```
HARNESS_MOBILE_E2E=1 HARNESS_SERVER_TOKEN=... \
  flutter test test/mobile_computer_e2e_test.dart
```

It starts a real `scripts/harness-server` with the `demo:scripted`
provider, connects the app's `AcpClient` and `MobileComputerController`
over the remote WebSocket, registers, creates a session, and prompts it
with `mobile computer demo`.  The provider calls `computer_camera`,
`computer_view`, and `computer_call` for files; the test asserts that the
calls reached the app's MCP servers, that the results are not errors, and
that the picture and the imported file's text came back.  The capture
port is the test's fake; the server, ACP transport, registration, token,
MCP host, tools, grants and file store are real.

What none of it proves is a real phone's screen or camera.  That needs
the platform capture ports and a device, and is stated as a blocker in
the hand-in rather than inferred from the no-op port.
