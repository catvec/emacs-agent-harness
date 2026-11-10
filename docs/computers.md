# Computers: the machines a session can use

A **client** and a **computer** are two different things, and the harness
keeps them apart.

- A *client* speaks ACP to the harness to read its state and enact
  actions: this Emacs's UI, a phone, a browser tab.  A client keeps no
  harness state; it shows what the harness sends and makes the requests
  the harness answers.
- A *computer* is a machine the harness may use.  It offers **tools**,
  as MCP servers a client on that machine runs and keeps, and
  **resources**: a git repository, a directory, a display, a graphics
  card.  A client may run *on* a computer and says so when it connects;
  that is a fact about the client, not a registration.
- A **session** runs on no computer.  It uses the tools of the computers
  it may reach.  A call that needs a machine names one, or leaves it to
  the session's preference.

The harness server alone keeps state and runs the event loop
(`harness-computers.el`, core module `computers`).  A computer keeps no
record of the harness: it answers the MCP messages the harness sends over
the ACP connection of the client that runs there, and its client runs and
manages the MCP servers.  The harness is an MCP host like any other; it
is never a program loaded on the computer.

The word is *computer* rather than *device* because a mouse, a graphics
card or a display is a device too, and the machine a session can use is a
larger thing than any one of them.  This repository's earlier vocabulary
used "device" for "the machine that runs commands"; the code, the
configuration and this document say `computer`.

## No computer of its own

The harness server has no computer of its own.  It keeps the harness's
state, calls completion providers and makes its own web requests; it runs
no tool for a session on the machine it happens to run on.  The coding
tools it ships (`bash`, the file tools, `elisp`) are harness modules that
run in a session's sandbox beside the server, not on a computer: they
have no computer id, and a deployment that leaves those modules out
offers only state and web tools.  See [sidecars and
programs](#sidecars-and-programs).

A machine becomes a computer only when a client running on it registers
it, and that is the same explicit act on the server's own machine as on a
phone or a laptop across the network: the computers page's
`[Registration]`, a client's own integration, or `computer/register`.
Nothing is registered on a client's behalf, and a client that says where
it runs in `initialize` only records a fact about itself.

Until a computer is registered the harness is a chat: its sessions have
the state, the model, the web tools and the coding tools when their
modules are loaded, and a tool that needs a computer says which one is
missing and how to register it.  A session may be
given a computer, or ask for one with `request_escalation`; a task may use
the computer of the project resource it works on; a workspace may use
every registered computer.

## Registering a computer

Registration is an explicit action that gives the harness access to a
machine.  It is made from a client running on that machine, and
the client is then responsible for the MCP servers that provide access
there:

1. The client authenticates to the harness like any ACP client (token,
   remote sign-in, or the local transport).
2. The user asks for registration (the computers page's
   `[Registration]`, `harness-register-computer`, or its own
   integration).
3. The client sends `_harness/computer/register` with its description of
   the computer (`:computer`, including `:vnc` and `:vnc-socket` when it
   shows a screen), a secret it made (`:secret`), the resources it offers
   (`:resources`) and the tool servers it runs (`:servers`).
4. The harness makes or updates the record, binds the computer to that
   ACP connection (`:client`), attaches its MCP servers over it, saves
   the record to `computers.json`, and answers with the record and the
   **MCP token** it will expect in every message to those servers.

The record is a plist (`harness-computers--describe` is its public
reading):

```elisp
(:id "cmp-host-ab12cd"        ; stable id, `cmp-HOST-RANDOM'
 :name "workstation"          ; the name people read, unique in the registry
 :kind client|ssh             ; how it is reached
 :host "…" :user "…"          ; an ssh registration's address, when known
 :state connected|registered|disconnected
 :connected t                 ; a client serves it now
 :window-scoped nil           ; its implementation can capture one window
 :capabilities ("view" "pointer" …) ; computer-use capabilities it offers
 :servers ("computer")        ; the MCP servers it runs
 :resources ((:kind "git-repo" :name "harness" :path "/home/…" :branch "main") …)
 :vnc "https://…"             ; a page where a person can watch its screen
 :vnc-socket "wss://…"        ; the RFB WebSocket a client draws instead
 :control "user"              ; who has its pointer and keyboard, if anyone
 :registered-at TIME :last-seen TIME)
```

A record that outlives the process comes back at start without its client
or its transport (`:client`, `:mcp`, `:mcp-token` are dropped), as
`registered` or `disconnected`; a client attaches it again with
`computer/attach` and the secret.  The secret itself is never stored: the
record keeps a random salt and the SHA-256 of `SALT:SECRET`, and a
comparison takes the same time whether the secrets differ early or late
(`harness-instance-equal-p`).

`computer/register-remote NAME :host HOST :user USER :resources … :vnc …`
records a computer reached over SSH, for the user, without a client on it
yet.  It reads `registered`; its tools start when a client on that
machine attaches with `computer/attach` and its secret.  The
harness-launched SSH provider -- the harness starting an MCP server on
that host itself, over a key it owns -- is the staged remainder; see
[Not yet](#not-yet).

### Authentication

A registration is protected in both directions:

- The ACP connection proves a client may speak to the harness at all:
  `harness-acp-token` locally, a remote sign-in over the network, or the
  local transport.
- The **secret** proves the client speaks for that computer.  It is 256
  random bits in base64url, made by the client, kept mode 600 in
  `harness-computer-endpoint-secret-file`, and sent once at
  registration; the harness keeps only its salted hash.  `computer/attach`
  presents it again after a reconnect.
- The **MCP token** (also 256 bits) is the harness's half of the same
  binding: the harness sends it with every `_harness/computer/mcp`
  request, and the client checks it before answering.  The harness serves
  a computer's MCP only on the connection of the client bound to it
  (`harness-computers--client-hosts-record-p`).

The MCP server the harness attaches is declared `:external`: the host
does not start a process, `harness-mcp-attach` gives it a send function,
and each message is an ACP request
`_harness/computer/mcp {computer, server, message, token}` (see
[mcp](architecture.md#mcp)).  The computer names itself and the server it
runs in every message, so one client can lend several computers and one
computer several servers.  This is the "strict authentication between the
MCP on the device and the harness server" the design calls for: an ACP
connection alone cannot drive a registered computer, and the MCP token
alone cannot either, since it travels only over that connection.

### Registration methods and events

| method | for |
| --- | --- |
| `computer/register` | a client on the computer registers it (or registers it again with the same secret) |
| `computer/register-remote` | the user records an SSH computer without a client there yet |
| `computer/attach` | a reconnecting client binds itself with the secret and gets a fresh token |
| `computer/update` | the client reports its resources, capabilities, display and screen again |
| `computer/unregister` | the user (or the client that registered it) removes it |
| `computer/list [SESSION-ID]` | every computer, with the session's standing when named |
| `computer/get ID` | one computer |
| `computer/access SESSION-ID` | what a session may use, and how each computer stands |
| `computer/resources [COMPUTER KIND]` | the resources of the computers |
| `computer/projects [SESSION-ID]` | the git repositories among them, across computers |
| `computer/grant SESSION-ID COMPUTER &:capabilities &:window` | the user grants a session a computer |
| `computer/revoke SESSION-ID COMPUTER &:capability` | the user takes it away |
| `computer/grant-capability SESSION-ID COMPUTER CAPABILITY ON` | one computer-use capability at a time |
| `computer/set-preference SESSION-ID COMPUTER` | the computer a nameless call uses |
| `computer/take-control ID` / `computer/release-control ID` | a person takes the pointer and keyboard, or gives them back |

`computers/check`, `computers/call` and `computers/tools` are the
harness's own, not callable over ACP: the permission gate and the tools
use them inside the process.

`computers/changed (ID WHAT)` is announced for `registered`, `updated`,
`attached`, `disconnected`, `preferred`, `granted`, `revoked`, `control`
and `removed`; it is forwarded to UIs, and the computers page refreshes
on it.

## Computer use

Computer use -- seeing a GUI, moving the pointer, typing, the clipboard,
audio -- is a generic interface with a fixed vocabulary of harness tools
(`harness-tools-computers.el`, module `tools-computers`), and a computer
declares which capabilities its implementation has.  This mirrors
completion providers: the harness offers one set of tools, and an
implementation answers what it can do.

| capability | what a call may do |
| --- | --- |
| `view` | see the screen, or one window |
| `windows` | list the desktop's windows |
| `pointer` | move, click, scroll, drag |
| `keyboard` | type text, press a key |
| `clipboard` | read and write the clipboard |
| `audio` | list audio devices, record a little |
| `sandbox` | a desktop separate from the computer's own |
| `exec` | run the computer's extra tools |
| `skills` | read the skills the computer advertises, and no file of it |

The capabilities are `harness-computers-capability-names`; a module may
add one with `harness-computers-define-capability`, with a doc for people
to read.  An implementation may be **window-scoped**
(`:window-scoped`): its `view` can name one window, not only the desktop,
and a session's grant may name that window and no other.  That is the
shape a Wayland compositor's portals fit (a window's stream and input for
it), as it is the shape of a sandboxed desktop: least privilege is a
window or a desktop, not the whole machine.

The fixed tools are:

- `computer_list` -- the computers, their state, capabilities, resources
  and what this session may use; `computer_tools` the extra tools one
  offers;
- `computer_view`, `computer_windows` -- look at a screen or list its
  windows;
- `computer_pointer`, `computer_keyboard`, `computer_clipboard` -- act
  there;
- `computer_call` -- call one of the extra tools an implementation offers
  (capability `exec`);
- `computer_use` -- the computer this session uses when a call names
  none.

Every tool names a computer (`:computer`, an id or a name) or leaves it
to the session's preference; each needs a capability, and the permission
chain's computer gate refuses, for good, a call to a computer the session
may not use, one whose grant does not hold the capability, one that drives
a computer a person has taken control of, and one the computer is not
connected for.  A screen capture comes back as bytes over MCP and is
written into the session's temporary directory, so the model sees the
picture where its provider reads images and the chat shows the
attachment.

**Missing computers and missing capabilities are guidance, not silence.**
A refusal says what is missing and what to do: `computer_list` for the
computers there are, `request_escalation` (attribute `computer`, with the
computer's id or name) for access, and "ask the user to start a client on
that computer and register it" when nothing offers the capability.  The
harness works with no computer at all: the state and web tools, and the
coding tools when their modules are loaded.  A computer tool called with
none registered says what is missing and how to register a computer.

### The client endpoint

`lisp/harness-computer-endpoint.el` is the client half: it describes the
computer the client runs on, runs the `computer` MCP server for it, and
registers or attaches it to a harness elsewhere.  What it offers is
detected from the machine:

- `view`: `grim` on Wayland, `scrot` or `import` on X11, or
  `x-export-frames` for this Emacs's own frames;
- `windows`: `swaymsg` on Wayland, `wmctrl` on X11, plus Emacs frames;
- `pointer`, `keyboard`: `xdotool`, `ydotool`, `wtype`; drag needs
  `xdotool`;
- `clipboard`: this Emacs's selection, so it needs a graphic display;
- `audio`: `pw-record` or `parecord` to record, `pactl` to list;
- `sandbox`: not a program but a *different desktop*: when
  `harness-computer-endpoint-display` names one, the programs act on that
  display, the clipboard is not read, and the computer says it is a
  desktop of its own.

A client can lend a **sandboxed desktop** from the same display seam: an
Xvfb, or any X display that is not the one the client draws in.  The
client's `scrot`, `wmctrl` and `xdotool` run against that display, and
`harness-computer-endpoint-vnc-url` and `-vnc-socket` name the VNC server
that shows the same framebuffer to a person and to an RFB client.  This
is how the computer-use demo runs: Xvfb and x11vnc on `:99`, the demo
page in Firefox, and the endpoint's screen, pointer and keyboard acting
on it (`scripts/computer-use-demo.sh`).

The MCP server answers `info`, `screenshot`, `windows`, `window`,
`pointer`, `keyboard`, `clipboard`, `audio` and `skills`; `initialize`
advertises the client's computer in
`clientCapabilities._harness.computer` (its id, name, host, OS,
architecture, display, VNC URL, window scope, capabilities and servers),
which the harness records as where the client runs, not as a
registration.  The id is stable per machine (`cmp-HOST-RANDOM`, kept in
`harness-computer-endpoint-id-file`), and the same client registering
again keeps it.

Resources come from `harness-computer-endpoint-resource-roots` (git
repositories at most `harness-computer-endpoint-resource-depth` levels
down), `harness-computer-endpoint-resources` (anything else a client
names) and `harness-computer-endpoint-skill-roots` (the skills on that
machine, one `skill` resource each; nil is the documented conventions,
`-skill-plugins` and `-skill-project` the plugins' and the project's).
A skill resource carries `:id`, `:name` and `:properties`
(`:description`, `:source`, `:origin`, `:version`, `:version-key`,
`:fingerprint`, `:files`), and the `skills` tool lists them, scans
again, or returns the content of one by its stable id and the
fingerprint the harness selected; see
[skills](design/skills-as-computer-resources.md).  Limits:
`harness-computer-endpoint-max-image-bytes`, `-max-text`,
`-max-audio-seconds`; a program's stderr and exit status are the error a
call reads.

## Permissions

A session's access to computers is part of the access profile and the
ordinary permission system, not a second system beside it:

- **Defaults.** `harness-computers-access` is a setting like the
  permission mode: a project or directory overrides it in
  `.dir-locals.el`, and a session's own grants and revocations override
  that.  `auto` (the default) is least privilege: the computer of the
  client the session was made from when it is registered, and the
  computers of the resources the session works on.  `all` is every
  registered computer; `none` is no computer at all.  A workspace episode
  gets every computer; a task session may use the computer of the project
  resource it works on; everything else is least privilege.
- **Grants and revocations.** The session ext `:computers` holds grants
  `(:computer ID :capabilities (NAMES…) :window NAME)`; `:computers-off`
  holds the computers it may not use at all; `:computer` is its preferred
  computer, which is not a pin -- a call that names a computer, or a
  resource of one, still goes where it names.  `harness-computers-access`
  computes the effective list: defaults, minus revocations, plus grants,
  each with the capabilities the session may use there.
- **Asking.** `request_escalation` (attribute `computer`, with an id or
  name, optional `capabilities` and `window`) asks the user for a
  computer.  Its stage makes every decision final: no mode, rule or judge
  sees it.  `drop_access` (attribute `computer`) gives it up at once,
  without asking, as it gives up a directory or the network.
- **Enforcing.** The module adds a stage at priority 7 of
  `permission/decide` (`harness-computers--gate`, stage `computer`).  A
  request whose `:computer` is nil passes; one for a computer not
  registered, not connected, not allowed to the session, without the
  capability the tool needs, or with a person in control of it and an
  input call, is denied for good with the reason and the hint the model
  reads.  The chain fails closed: a gate that signals refuses the call.
  The tool registry says which computer and capability a tool needs
  (`harness-define-tool :computer :capability`), and
  `harness-tools--computer-fields` puts it in the request, so the gate
  sees every call, whatever its input.
- **Reading it.** `access/describe` has `:computers` (`computer/access`'s
  plist), the access view shows it, and `session_info` says which
  computers the session may use, with which capabilities, which are
  registered and connected, which computer a nameless call would use, and
  which it may not use and how to ask.
- **A person's use is not a session's.** Viewing a computer is not a
  session permission: every client sees every computer it can reach, and
  the computers page's `[View]` opens the screen a computer offers (its
  VNC page), whether or not a session may use it.  `[Control]` takes the
  pointer and the keyboard from the agent until `[Return]`; the gate
  refuses the agent's input on a computer a person controls and says so.
  Only what a session's agent may do there is gated.

### Sidecars and programs

A program the harness runs for itself -- a transcription program, a voice
pipeline's WebRTC endpoint -- is not a computer's tool server.  It runs
where its work is: next to the harness server when it offers an API other
processes share (the live voice pipeline, so every client can connect to
one), or in a session's sandbox when it only serves that session.  None of
it runs on a computer's client for the harness's own work; a computer runs
an MCP server only when its tools act on that computer.  This keeps the
server the only place state and inference live, and keeps a client on a
computer from becoming a second server by accident.

The local voice pipeline follows that rule to the letter.  The `speech`
module (`lisp/modules/harness-speech.el`) runs whisper.cpp and Kokoro as
the harness server's children, or the bundled `voice-local` compose stack,
and keeps them on loopback: the services answer no authentication, so they
are not published to the network.  A client anywhere asks the harness for
speech on the connection it already has -- `_harness/speech/transcribe`
takes base64 WAV and answers text, `_harness/speech/synthesize` takes text
and answers a WAV -- so a phone's dictation needs no whisper.cpp, no Kokoro
and no docker, and a client on the harness's own machine may use the
loopback URLs `_harness/speech/status` reports instead.  The microphone and
the speaker stay with the client; only the speech crosses.  See
[voice](voice.md) and
[the design](design/server-voice-pipeline.md).

## Resources and projects

A resource is identified by its computer and a stable id, not by a path of
the harness's machine:

```elisp
(:id "res-…" :kind "git-repo" :name "harness"
 :path "/home/me/src/emacs-agent-harness"  ; the path that computer knows
 :branch "main" :computer "cmp-host-ab12cd" :computer-name "workstation"
 :project t)
```

Kinds are `git-repo`, `directory`, `display`, `gpu`, `audio`, and
anything else a client names.  The same repository can be a resource of
several computers, each with its own path, branch and worktrees.
`computer/resources` lists them, filtered by computer and kind;
`computer/projects` is the computer-independent list of git repositories
the computers offer, which is how projects are discovered from what
computers report.  The list is empty until a client registers a computer
that offers a repository.  A project on a computer is named by its
resource, not by a path; the path is what a tool on that computer needs,
and the harness never assumes it exists here.

Taking a worktree out for a task still runs git in the harness's own
sandbox for now: a task whose project is a resource of another computer
is the staged remainder; see [Not yet](#not-yet).

## The computers page

`lisp/ui/harness-ui-computers.el` (module `ui-computers`, key
`C-c h V E`, command `harness-computers`) is the page a person uses.  It
talks ACP only, so it shows the harness it is connected to, on this
machine or another, the same way.

It has four sections:

- **This client**: the computer this client runs on, its id, whether it
  is registered, its capabilities, and `[Registration]`, `[Resource refresh]`
  (resources reported again) and `[Computer list]` (the page fetched
  again).
- **Computers**: one row per computer -- name, id, kind, state
  (connected, registered, not connected), capabilities, resources, who
  has control -- with `[View]`, `[Control]`/`[Return]` and
  `[Unregistration]`.
- **Session access**: the page's session, its policy and preferred
  computer, and for each computer whether it is allowed and why, with a
  button per capability (`[view]`, `[pointer]`, …) that grants or revokes
  it, `[Grant]`/`[Revocation]` and `[Preference]`.
- **Resources**: the resources of the computers, with their computer and
  path.

The page's keys are its buttons: `g` refresh, `r` register this client's
computer, `R` report its resources again, `u` unregister, `a` grant and
`x` revoke the computer at point, `s` prefer it, `V` view its screen, `c`
take control and `C` return it, `?` the menu.  Empty, loading, success
and failure states are words: "no computer registered", "no session",
"no resource", "…", "registration", and
"registration failure: REASON" in the echo area.  Every word is a noun
phrase or an adjective, the menu's included: its entries say what they
are for (`Registration of this computer`, `Screen view of the computer
at point`), never a sentence.  `harness-ui-computers-test` asserts the
rendered words and tooltips, and the menu entries with them.

## The Flutter client

`harness_client/lib/src/ui/screens/computers_screen.dart` draws the same
registry for the phone and the desktop app: the machines, their state and
computer-use capabilities, the open session's policy, grants and preferred
computer, and the resources across them.  It reads `computer/list`,
`computer/access`, `computer/resources`, `computer/grant`,
`computer/revoke`, `computer/grant-capability`, `computer/set-preference`,
`computer/take-control` and `computer/release-control`, and follows
`computers/changed`.

A computer with a `vnc-socket` opens its screen on
`computer_screen.dart`: the app's own RFB client (`lib/src/vnc/`) draws
the framebuffer, and, while a person has control, sends the pointer and
the keyboard back.  A computer with only a `vnc` page says `No screen
socket` and shows the page's address; the app never pretends a page is a
stream.  The route is under Server -> Computers, and the page's copy is
noun phrases like the Emacs page's: `Computers`, `Session`, `Machines`,
`Resources`, `View`, `Control`, `Return`, `Grant`, `Revocation`,
`Preference`, `No computers`, `No resources`, `No session`, `No screen
socket`, `View only`, `Screen lost`.  `harness_client/test/computers_test.dart`
asserts them, and `test/computers_screenshots_test.dart` takes the
pictures.

The app is a computer too.  `MobileComputerController` and
`MobileComputerEndpoint` (`harness_client/lib/src/computer/`) make an
identity and a 256-bit secret for the installation and register this
device with `computer/register` when the person presses `[Registration]`
on the page; `[Reconnection]` presents the same secret to a restarted
harness with `computer/attach`.  The app runs its MCP servers in the app
process, not as separate programs: the `computer` server offers screen,
camera, microphone, clipboard and information tools, and the `files`
server offers the app's scoped `imports/` and `outbox/` directories.
Every message comes over the existing ACP connection as
`_harness/computer/mcp`, checked against the computer id, the server name
and the registration's MCP token.  An in-process server has no socket of
its own for a harness to reach: the ACP connection is the transport, and
a client that leaves takes its tools with it.  The identity, the
capability choices and the file scope are in
[mobile-computer](mobile-computer.md).

## What is not yet

These are the parts of the design deliberately left for later, with what
the code does now:

- **The SSH provider.** An SSH-registered computer is recorded with its
  host, user, resources and VNC URL, and reads `registered`.  A client on
  that machine can attach it with its secret; the harness does not yet
  start an MCP server there over SSH itself.  The record is what such a
  provider will use.
- **Remote worktrees.** A task whose project is a resource of another
  computer is not given a worktree there yet; the worktree module runs
  git beside the harness.  The project resource names the computer and
  the path a remote worktree tool would use.
- **Managed sandboxed desktops.** The endpoint can lend an X display that
  is not its own (`harness-computer-endpoint-display`), and that is what
  the demo uses.  A computer that starts and stops its own headless
  desktop, per session, and a Wayland portal's window scope are the
  remaining implementation of the same tools; a person still starts the
  demo's Xvfb.
- **Audio streaming.** The endpoint records a bounded clip and returns
  it as bytes; a live audio stream (for a voice call) is the voice
  pipeline's work, not a computer-use call.
- **Window scoping on Wayland input.** Window-scoped capture is detected
  and granted; window-scoped input needs a compositor portal, which the
  endpoint does not use yet -- it types into the desktop as a whole.
- **Real device capture.** The app's registration, its MCP servers and
  its file and clipboard tools are real.  Screen, camera and microphone
  sit behind `ComputerCapturePort`, and this build ships the no-op port:
  the capability rows read `Unavailable` until a platform port provides
  them.  Android needs a `MediaProjection` consent flow and a foreground
  service, and iOS needs a ReplayKit broadcast upload extension; those
  platform ports are the remaining work, not a change to the harness
  contract.  The E2E test exercises the tools with a fake port.  The ACP
  contract is in [architecture](architecture.md#computers), and the
  app's side in [mobile-computer](mobile-computer.md).

## Decisions and alternatives

- **A computer is not a client, and not a session's host.** The older
  model ran a session "on" the machine where its tools ran, and a server
  with no client registered had a computer of its own.  Making the
  computer a first-class thing means a session can use several machines,
  a machine can serve several sessions, and a machine can be attached or
  detached without moving the session.  The server keeps no computer: it
  is a chat until a client registers one, and the coding tools it ships
  are its own sandboxed modules, not a computer.
- **Registration is explicit and made from the computer itself.** A
  server cannot reach out and enroll a machine because it knows a name:
  the client on the machine makes the secret and sends it.  The SSH
  record is the one made on the server's side, and it stays inert until
  a client on the other side attaches.
- **The server keeps state; the client runs the servers.** Letting a
  client keep records or make completion calls would make every client a
  second harness and every reconnection a merge.  It runs MCP servers
  because its tools act on its machine; everything else is the server's.
- **A device's tools travel as MCP over ACP.** A second port or a
  bespoke wire protocol would be another authentication story to get
  right.  An ACP request to the bound client carries the MCP message; the
  existing MCP host, with its handshake, progress and timeouts, is the
  host on both ends.  The strict authentication is two-sided: the ACP
  connection and the computer's secret/token.
- **Defaults are least privilege, and a preference is not a pin.**
  A session gets the computer its client registered and the computers of
  its resources; a workspace gets every one; anything else is asked for.
  A preferred computer only decides nameless calls: the interesting
  association is the resource a session works on, which names its
  computer by itself.
- **Projects are resources, not paths.** A path is a property of one
  computer's copy.  Keeping projects as resource ids lets the same
  project be worked on from several machines, each with its own path and
  branch.

## Checking it

`lisp/modules/harness-computers-test.el` (registry, access, the gate, resources,
the store, the screen endpoints), `lisp/harness-computer-endpoint-test.el`
(the client's capabilities, the lent display, MCP server, registration and
attachment), `lisp/modules/harness-tools-computers-test.el` (the tools' words and
their answers), and `lisp/ui/harness-ui-computers-test.el` (the page's
rendered copy, tooltips, keys and command).  The Flutter client's are
`harness_client/test/computers_test.dart`,
`test/computers_screenshots_test.dart` and
`test/computer_endpoint_test.dart` (identity, file scope, MCP server,
registration, the handshake that arrives before the token, capture stop
and revocation), plus the guarded
`test/mobile_computer_e2e_test.dart`, which starts a real harness server
and calls the tools over ACP.  The live page is in the harness UI
under `C-c h V E`; the demo in the task's hand-in starts it with a
registered computer.

`scripts/computer-use-demo.sh start` starts the demo's private X display,
its x11vnc and noVNC bridge, and Firefox on a page the agent can see and
drive.  It prints the display, the VNC page and the RFB socket; the hand-in
shows the same screen in the Emacs page, the noVNC page and the Flutter
app, with the agent's `computer_view`, `computer_windows`, `computer_pointer`
and `computer_keyboard` calls in its transcript.
